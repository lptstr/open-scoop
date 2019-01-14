#   
#   FILE: BUILD.PS1 
#   TYPE: PWSH_SCRIPT
#
#   This file is used by a bot (KIEDTL-MACHINE) to 
#   automatically update Open-Scoop application manifests
#   and add appropriate tags.
#
#   BUCKET MAINTAINERS: This script assumes that 
#   Open-Scoop is location in SCOOPDIR/proj/open-scoop. It 
#   also assumes that Scoop is installed in 
#   $env:USERPROFILE\scoop.
#   
#   Please do not edit this file. Any pull requests
#   with this file edited WILL NOT be accepted.
#       _            _
#    __| |_ __ _ _ _| |
#   (_-<  _/ _` | '_|  _|
#   /__/\__\__,_|_|  \__|
# 

param (
	[switch]$NoTag = $false,
	[switch]$NoUpdate = $false
)

$USER = $env:USERNAME
$OPENSCOOPDIR = "C:\Users\$USER\scoop\proj\open-scoop"
$SCOOP = scoop which scoop
if ( !$env:SCOOP_HOME ) { 
  $env:SCOOP_HOME = resolve-path (split-path (split-path (scoop which scoop))) 
}
$checkver = "C:\\Users\\$USER\\scoop\\apps\\scoop\\current\\bin\\checkver.ps1"
$dir = "C:\\Users\\$USER\\scoop\\proj\\open-scoop" 
$DATETIME = Get-Date

# Checkout update-manifest branch
git checkout update-manifest

# Copyright (c) 2013 - 2018 Luke Sampson and other Scoop contributers and/or maintainers
# Taken from the Scoop repository (file lib/json.ps1)
# Needed for the build.ps1 script

function ConvertToPrettyJson {
    [CmdletBinding()]

    Param (
        [Parameter(Mandatory, ValueFromPipeline)]
        $data
    )

    Process {
        $data = normalize_values $data

        # convert to string
        [String]$json = $data | ConvertTo-Json -Depth 8 -Compress
        [String]$output = ''

        # state
        [String]$buffer = ''
        [Int]$depth = 0
        [Bool]$inString = $false

        # configuration
        [String]$indent = ' ' * 4
        [Bool]$unescapeString = $true
        [String]$eol = "`r`n"

        for ($i = 0; $i -lt $json.Length; $i++) {
            # read current char
            $buffer = $json.Substring($i, 1)

            $objectStart = !$inString -and $buffer.Equals('{')
            $objectEnd = !$inString -and $buffer.Equals('}')
            $arrayStart = !$inString -and $buffer.Equals('[')
            $arrayEnd = !$inString -and $buffer.Equals(']')
            $colon = !$inString -and $buffer.Equals(':')
            $comma = !$inString -and $buffer.Equals(',')
            $quote = $buffer.Equals('"')
            $escape = $buffer.Equals('\')

            if ($quote) {
                $inString = !$inString
            }

            # skip escape sequences
            if ($escape) {
                $buffer = $json.Substring($i, 2)
                ++$i

                # Unescape unicode
                if ($inString -and $unescapeString) {
                    if ($buffer.Equals('\n')) {
                        $buffer = "`n"
                    } elseif ($buffer.Equals('\r')) {
                        $buffer = "`r"
                    } elseif ($buffer.Equals('\t')) {
                        $buffer = "`t"
                    } elseif ($buffer.Equals('\u')) {
                        $buffer = [regex]::Unescape($json.Substring($i - 1, 6))
                        $i += 4
                    }
                }

                $output += $buffer
                continue
            }

            # indent / outdent
            if ($objectStart -or $arrayStart) {
                ++$depth
            } elseif ($objectEnd -or $arrayEnd) {
                --$depth
                $output += $eol + ($indent * $depth)
            }

            # add content
            $output += $buffer

            # add whitespace and newlines after the content
            if ($colon) {
                $output += ' '
            } elseif ($comma -or $arrayStart -or $objectStart) {
                $output += $eol
                $output += $indent * $depth
            }
        }

        return $output
    }
}

function json_path([String] $json, [String] $jsonpath, [String] $basename) {
    Add-Type -Path "$psscriptroot\..\supporting\validator\bin\Newtonsoft.Json.dll"
    $jsonpath = $jsonpath.Replace('$basename', $basename)
    try {
        $obj = [Newtonsoft.Json.Linq.JObject]::Parse($json)
    } catch [Newtonsoft.Json.JsonReaderException] {
        return $null
    }

    try {
        $result = $obj.SelectToken($jsonpath, $true)
        return $result.ToString()
    } catch [System.Management.Automation.MethodInvocationException] {
        write-host -f DarkRed $_
        return $null
    }

    return $null
}

function json_path_legacy([String] $json, [String] $jsonpath, [String] $basename) {
    $result = $json | ConvertFrom-Json -ea stop
    $isJsonPath = $jsonpath.StartsWith('$')
    $jsonpath.split('.') | ForEach-Object {
        $el = $_

        # substitute the base filename into the jsonpath
        if ($el.Contains('$basename')) {
            $el = $el.Replace('$basename', $basename)
        }

        # skip $ if it's jsonpath format
        if ($el -eq '$' -and $isJsonPath) {
            return
        }

        # array detection
        if ($el -match '^(?<property>\w+)?\[(?<index>\d+)\]$') {
            $property = $matches['property']
            if ($property) {
                $result = $result.$property[$matches['index']]
            } else {
                $result = $result[$matches['index']]
            }
            return
        }

        $result = $result.$el
    }
    return $result
}

function normalize_values([psobject] $json) {
    # Iterate Through Manifest Properties
    $json.PSObject.Properties | ForEach-Object {
        # Recursively edit psobjects
        # If the values is psobjects, its not normalized
        # For example if manifest have architecture and it's architecture have array with single value it's not formatted.
        # @see https://github.com/lukesampson/scoop/pull/2642#issue-220506263
        if ($_.Value -is [System.Management.Automation.PSCustomObject]) {
            $_.Value = normalize_values $_.Value
        }

        # Process String Values
        if ($_.Value -is [String]) {

            # Split on new lines
            [Array] $parts = ($_.Value -split '\r?\n').Trim()

            # Replace with string array if result is multiple lines
            if ($parts.Count -gt 1) {
                $_.Value = $parts
            }
        }

        # Convert single value array into string
        if ($_.Value -is [Array]) {
            # Array contains only 1 element String or Array
            if ($_.Value.Count -eq 1) {
                # Array
                if ($_.Value[0] -is [Array]) {
                    $_.Value = $_.Value
                } else {
                    # String
                    $_.Value = $_.Value[0]
                }
            } else {
                # Array of Arrays
                $resulted_arrs = @()
                foreach ($element in $_.Value) {
                    if ($element.Count -eq 1) {
                        $resulted_arrs += $element
                    } else {
                        $resulted_arrs += , $element
                    }
                }

                $_.Value = $resulted_arrs
            }
        }

        # Process other values as needed...
    }

    return $json
}


# End copyrighted file


function parse_json($path) {    if(!(Test-Path $path)) {         return $null     }    Get-Content $path -raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop}

Set-Location $HOME
Set-Location scoop/proj/open-scoop/bin

git pull > log.txt

if (!$NoUpdate) {
	$files = Get-ChildItem ../.\*.json
	$i = 1;
	Get-ChildItem ../.\*.json | Foreach-Object {
	  $basename = $_.BaseName	  
	$name = $_.Name
	  Write-Progress -Activity "Updating application manifests" -status "Scanning $name" -percentComplete ($i / $files.count * 100)	  
	$out = ../../../apps/scoop/current/bin/checkver.ps1 -dir $dir -App $basename -u | Out-String
	  git commit -q -a -m "Auto-updated $basename" > log.txt
	  $i++
	}
	
	Write-Output "`a"
	
	
	Set-Content -Path "../APPLIST.md" -Value " "
	Add-Content -Path "../APPLIST.md" -Value "### List of apps`n---`n**Note**: This section is automatically generated by the bin/build.ps1 script.`r`n`r`n" -NoNewline
	
	Add-Content -Path "../APPLIST.md" -Value "| Name | Version | Homepage |`r`n" -NoNewline
	Add-Content -Path "../APPLIST.md" -Value "| ---- | ------- | -------- |`r`n" -NoNewline
	
	Get-ChildItem ../.\*.json | Foreach-Object {
		$appname = $_.BaseName
		$appdata = Get-Content $_ | ConvertFrom-JSON
		$homepage = $appdata.homepage
		$version = $appdata.version
		Add-Content -Path "../APPLIST.md" -Value "| $appname | $version | [$homepage]($homepage) |`r`n" -NoNewline
	}
	
	Add-Content -Path "../APPLIST.md" -Value "`nThis section was last generated on $DATETIME"
	
	git add ../APPLIST.md
	git commit -q -m "Automatically updated APPLIST.md"
	
	Write-Output "Finished updating app manifests"
}

git checkout master
git merge update-manifest

git checkout format-manifest
git merge update-manifest

# Format each file
$c = 1
$manifests = Get-ChildItem ../.\*.json
Get-ChildItem ../.\*.json | ForEach-Object {
   $name = $_.Namee
    $basename = $_.BaseName
    $json = parse_json "$_" | ConvertToPrettyJson
    Write-Progress -Activity "Formatting JSON in application manifests" -status "Formatting $_" -percentComplete ($c / $manifests.count * 100)


    [System.IO.File]::WriteAllLines("$_", $json)
    git commit -q -a -m "Automatically formated JSON in $basename's manifest" > log.txt    Write-Output "Formatted $_"
    $c++
}
git checkout master
git merge format-manifest
git merge update-manifest

# Commit and tagging

Set-Location ..

if (!$NoTag) {
	$smajor = Get-Content versdat/major.txt
	$sminor = Get-Content versdat/minor.txt
	$sbuild = Get-Content versdat/build.txt
	$major = [int]$smajor
	$minor = [int]$sminor
	$build = [int]$sbuild
	
	if ($build -gt 25 -and $minor -lt 25) {
		$minor++
		$build = 0
	}
	elseif ($build -gt 25 -and $minor -gt 25) {
		$build = 0
		$minor = 0
		$major++
	}
	else {
		$build++
	}
	
	$smajor = [string]$major
	$sminor = [string]$minor
	$sbuild = [string]$build
	
	Set-Content -Path versdat/major.txt -Value $smajor
	Set-Content -Path versdat/minor.txt -Value $sminor
	Set-Content -Path versdat/build.txt -Value $sbuild

	git commit -a -m "Automatically bumped version number in the versdat directory"

	Write-Output "Creating GitHub release ${smajor}.${sminor}.${sbuild}"
	$version = "${smajor}.${sminor}.${sbuild}"
	$latestcommit = git rev-parse HEAD
	git tag -a -m "Automatically_added_tag_$version" "v$version" $latestcommit 
}

Write-Output "`a"
Remove-Item bin/log.txt
