data LocalizedData
{
    # culture="en-US"
    # TODO: Support WhatIf
    ConvertFrom-StringData @'
InvalidChecksumArgsMessage=Specifying a Checksum without requesting content validation (the Validate parameter) is not meaningful
InvalidDestinationDirectory=The specified destination directory {0} does not exist or is not a directory
InvalidSourcePath=The specified source file {0} does not exist or is not a file
ErrorOpeningExistingFile=An error occurred while opening the file {0} on disk. Please examine the inner exception for details
ErrorOpeningArchiveFile=An error occurred while opening the archive file {0}. Please examine the inner exception for details
ItemExistsButIsWrongType=The named item ({0}) exists but is not the expected type, and Force was not specified
ItemExistsButIsIncorrect=The destination file {0} has been determined not to match the source, but Force has not been specified. Cannot continue
ErrorCopyingToOutstream=An error was encountered while copying the archived file to {0}
PackageUninstalled=The archive at {0} was removed from destination {1}
PackageInstalled=The archive at {0} was unpacked to destination {1}
ConfigurationStarted=The configuration of MSFT_ArchiveResource is starting
ConfigurationFinished=The configuration of MSFT_ArchiveResource has completed
MakeDirectory=Make directory {0}
RemoveFileAndRecreateAsDirectory=Remove existing file {0} and replace it with a directory of the same name
RemoveFile=Remove file {0}
RemoveDirectory=Remove directory {0}
UnzipFile=Unzip archived file to {0}
DestMissingOrIncorrectTypeReason=The destination file {0} was missing or was not a file
DestHasIncorrectHashvalue=The destination file {0} exists but its checksum did not match the origin file
DestShouldNotBeThereReason=The destination file {0} exists but should not
'@
}

$Debug = $false
Function Trace-Message
{
    param([string] $Message)
    if($Debug)
    {
        Write-Verbose $Message
    }
}

$CacheLocation = "$env:systemroot\system32\Configuration\BuiltinProvCache\MSFT_ArchiveResource"


Function Get-CacheEntry
{
    $key = [string]::Join($args).GetHashCode().ToString()
    Trace-Message "Using ($key) to retrieve hash value"
    $path = Join-Path $CacheLocation $key
    if(-not (Test-Path $path))
    {
        Trace-Message "No cache value found"
        return @{}
    }
    else
    {
        $tmp = Import-CliXml $path
        Trace-Message "Cache value found, returning $tmp"
        return $tmp
    }
}

Function Set-CacheEntry
{
    param([object] $InputObject)
    $key = [string]::Join($args).GetHashCode().ToString()
    Trace-Message "Using $tmp ($key) to save hash value"
    $path = Join-Path $CacheLocation $key
    Trace-Message "About to cache value $InputObject"
    if(-not (Test-Path $CacheLocation))
    {
        mkdir $CacheLocation | Out-Null
    }
    
    Export-CliXml -Path $path -InputObject $InputObject
}

Function Throw-InvalidArgumentException
{
    param(
        [string] $Message,
        [string] $ParamName
    )
    
    $exception = new-object System.ArgumentException $Message,$ParamName
    $errorRecord = New-Object System.Management.Automation.ErrorRecord $exception,$ParamName,"InvalidArgument",$null
    throw $errorRecord
}

Function Throw-TerminatingError
{
    param(
        [string] $Message,
        [System.Management.Automation.ErrorRecord] $ErrorRecord,
        [string] $ExceptionType
    )
    
    $exception = new-object "System.InvalidOperationException" $Message,$ErrorRecord.Exception
    $errorRecord = New-Object System.Management.Automation.ErrorRecord $exception,"MachineStateIncorrect","InvalidOperation",$null
    throw $errorRecord
}

Function Assert-ValidStandardArgs
{
    param(
        [string] $Path,
        [string] $Destination,
        [boolean] $Validate,
        [string] $Checksum
    )
    
    #mkdir and Test-Path can each fail with a useful error message
    #We want to stop our execution if that happens
    $ErrorActionPreference = "Stop"
    
    if(-not (Test-Path -PathType Leaf $Path))
    {
        Throw-InvalidArgumentException ($LocalizedData.InvalidSourcePath -f $Path) "Path"
    }
    
    $item = Get-Item -EA Ignore $Destination
    if($item -and $item.GetType() -eq [System.IO.FileInfo])
    {
        Throw-InvalidArgumentException ($LocalizedData.InvalidDestinationDirectory -f $Destination) "Destination"
    }
    
    if($Checksum -and -not $Validate)
    {
        Throw-InvalidArgumentException ($LocalizedData.InvalidChecksumArgsMessage -f $Checksum) "Checksum"
    }
}

Function Get-Hash
{
    param(
        [System.IO.Stream] $Stream,
        [string] $Algorithm
    )
    
    $hashGenerator = $null
    $hashNameToType = @{
        #This is the sort of thing that normally is declared as a global constant, but referencing the type incurs cost
        #that we're trying to avoid in some cold-start cases
        "sha-1" = [System.Security.Cryptography.SHA1]
        "sha-256" = [System.Security.Cryptography.SHA256];
        "sha-512" = [System.Security.Cryptography.SHA512]
    }
    $algorithmType = $hashNameToType[$Algorithm]
    try
    {
        $hashGenerator = $algorithmType::Create() #All types in the dictionary will have this method
        [byte[]]$hashGenerator.ComputeHash($Stream)
    }
    finally
    {
        if($hashGenerator)
        {
            $hashGenerator.Dispose()
        }
    }
}

Function Compare-FileToEntry
{
    param(
        [string] $FileName,
        [object] $Entry,
        [string] $Algorithm
    )
    
    $existingStream = $null
    $hash1 = $null
    try
    {
        $existingStream = New-Object System.IO.FileStream $FileName, "Open"
        $hash1 = Get-Hash $existingStream $Algorithm
    }
    catch
    {
        Throw-TerminatingError ($LocalizedData.ErrorOpeningExistingFile -f $FileName) $_
    }
    finally
    {
        if($existingStream -ne $null)
        {
            $existingStream.Dispose()
        }
    }
    
    $hash2 = $Entry.Checksum
    for($i = 0; $i -lt $hash1.Length; $i++)
    {
        if($hash1[$i] -ne $hash2[$i])
        {
            return $false
        }
    }
    
    return $true
}

Function Get-RelevantChecksumTimestamp
{
    param(
        [System.IO.FileSystemInfo] $FileSystemObject,
        [String] $Checksum
    )
    
    if($Checksum.Equals("createddate"))
    {
        return $FileSystemObject.CreationTime
    }
    else #$Checksum.Equals("modifieddate")
    {
        return $FileSystemObject.LastWriteTime
    }
}

Function Update-Cache
{
    param(
        [Hashtable] $CacheObject,
        [System.IO.Compression.ZipArchiveEntry[]] $Entries,
        [string] $Checksum,
        [string] $SourceLastWriteTime
    )
    
    Trace-Message "In Update-Cache"
    $cacheEntries = new-object System.Collections.ArrayList
    foreach($entry in $Entries)
    {
        $hash = $null
        if($Checksum.StartsWith("sha"))
        {
            $stream = $null
            try
            {
                $stream = $entry.Open()
                $hash = Get-Hash $stream $Checksum
            }
            finally
            {
                if($stream)
                {
                    $stream.Dispose()
                }
            }
        }
        
        Trace-Message "Adding $entry.FullName as a cache entry"
        $cacheEntries.Add(@{
            FullName = $entry.FullName
            LastWriteTime = $entry.LastWriteTime
            Checksum = $hash
        }) | Out-Null
    }
    
    Trace-Message "Updating CacheObject"
    $CacheObject["SourceLastWriteTime"] = $SourceLastWriteTime
    $CacheObject["Entries"] = (@() + $cacheEntries)
    Set-CacheEntry -InputObject $CacheObject $Path $Destination
    Trace-Message "Placed new cache entry"
}

Function Normalize-Checksum
{
    param(
        [boolean] $Validate,
        [string] $Checksum
    )
    
    if($Validate)
    {
        if(-not $Checksum)
        {
            $Checksum = "SHA-256"
        }
        
        $Checksum = $Checksum.ToLower()
    }
    
    Trace-Message "Normalize-Checksum returning $Checksum"
    return $Checksum
}

# The Test-TargetResource cmdlet is used to test the status of item on the destination
function Test-TargetResource
{
    param
    (
        [ValidateSet("Present", "Absent")]
        [string] $Ensure = "Present",
        
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,
        
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Destination,
        
        [boolean] $Validate = $false,
        
        [ValidateSet("", "SHA-1", "SHA-256", "SHA-512", "CreatedDate", "ModifiedDate")]
        [string] $Checksum,

        [boolean] $Force = $false
    )

    $ErrorActionPreference = "Stop"
    
    Trace-Message "About to validate standard arguments"
    Assert-ValidStandardArgs $Path $Destination $Validate $Checksum
    $Checksum = Normalize-Checksum $Validate $Checksum
    Trace-Message "Going for cache entries"
    $result = $true
    $cacheObj = Get-CacheEntry $Path $Destination
    $sourceLastWriteTime = (Get-Item $Path).LastWriteTime
    $cacheUpToDate = $cacheObj -and $cacheObj.SourceLastWriteTime -and $cacheObj.SourceLastWriteTime -eq $sourceLastWriteTime
    $file = $null
    try
    {
        $entries = $null
        if($cacheUpToDate)
        {
            Trace-Message "The cache was up to date, using cache to satisfy requests"
            $entries = $cacheObj.Entries
        }
        else
        {
            Trace-Message "About to open the zip file"
            $entries, $null, $file = Open-ZipFile $Path
            
            Trace-Message "Updating cache"
            Update-Cache $cacheObj $entries $Checksum $sourceLastWriteTime
            $entries = $cacheObj.Entries
            Trace-Message ("Cache updated with {0} entries" -f $cacheObj.Entries.Length)
        }
        
        foreach($entry in $entries)
        {
            $individualResult = $true
            Trace-Message ("Processing {0}" -f $entry.FullName)
            $dest = join-path $Destination $entry.FullName
            if($dest.EndsWith('\')) #Directory
            {
                $dest = $dest.TrimEnd('\')
                if(-not (Test-Path -PathType Container $dest))
                {
                    Write-Verbose ($LocalizedData.DestMissingOrIncorrectTypeReason -f $dest)
                    $individualResult = $result = $false
                }
            }
            else
            {
                $item = Get-Item $dest -EA Ignore
                if(-not $item)
                {
                    $individualResult = $result = $false
                }
                elseif($item.GetType() -ne [System.IO.FileInfo])
                {
                    $individualResult = $result = $false
                }
                
                if(-not $Checksum)
                {
                    Trace-Message "In Test-TargetResource: $dest exists, not using checksums, continuing"
                    if(-not $individualResult -and $Ensure -eq "Present")
                    {
                        Write-Verbose ($LocalizedData.DestMissingOrIncorrectTypeReason -f $dest)
                    }
                    elseif($individualResult -and $Ensure -eq "Absent")
                    {
                        Write-Verbose ($LocalizedData.DestShouldNotBeThereReason -f $dest)
                    }
                }
                else
                {
                    #If the file is there we need to check if it could possibly fail in a different way
                    #Otherwise we skip all these checks - there's nothing to work with
                    if($individualResult)
                    {
                        $Checksum = $Checksum.ToLower()
                        if($Checksum.StartsWith("sha"))
                        {
                            if($item.LastWriteTime.Equals($entry.ExistingItemTimestamp))
                            {
                                Trace-Message "Not performing checksum, the file on disk has the same write time as the last time we verified its contents"
                            }
                            else
                            {
                                if(-not (Compare-FileToEntry $dest $entry $Checksum))
                                {
                                    $individualResult = $result = $false
                                }
                                else
                                {
                                    $entry.ExistingItemTimestamp = $item.LastWriteTime
                                    Trace-Message "$dest exists and the hash matches even though the LastModifiedTime didn't (for some reason) updating cache"
                                }
                            }
                        }
                        else
                        {
                            $date = Get-RelevantChecksumTimestamp $item $Checksum
                            if(-not $date.Equals($entry.LastWriteTime.DateTime))
                            {
                                $individualResult = $result = $false
                            }
                            else
                            {
                                Trace-Message "In Test-TargetResource: $dest exists and the selected timestamp ($Checksum) matched"
                            }
                        }
                    }
                    
                    if(-not $individualResult -and $Ensure -eq "Present")
                    {
                        Write-Verbose ($LocalizedData.DestHasIncorrectHashvalue -f $dest)
                    }
                    elseif($individualResult -and $Ensure -eq "Absent")
                    {
                        Write-Verbose ($LocalizedData.DestShouldNotBeThereReason -f $dest)
                    }
                }
            }
        }
    }
    finally
    {
        if($file)
        {
            $file.Dispose()
        }
    }
    
    Set-CacheEntry -InputObject $cacheObj $Path $Destination
    $result = $result -eq ("Present" -eq $Ensure)
    return $result
}
        
Function Ensure-Directory
{
    param([string] $Dir)
    $item = get-item $Dir -EA SilentlyContinue
    if(-not $item)
    {
        Trace-Message "Folder $Dir does not exist"
        if($PSCmdlet.ShouldProcess(($LocalizedData.MakeDirectory -f $Dir), $null, $null))
        {
            mkdir $Dir | Out-Null
        }
    }
    else
    {
        if($item.GetType() -ne [System.IO.DirectoryInfo])
        {
            if($Force -and $PSCmdlet.ShouldProcess(($LocalizedData.RemoveFileAndRecreateAsDirectory -f $Dir), $null, $null))
            {
                Trace-Message "Removing $Dir"
                rm $Dir | Out-Null
                mkdir $Dir | Out-Null #Note that we don't do access time translations onto directories since we are emulating the shell's behavior
            }
            else
            {
                Throw-TerminatingError ($LocalizedData.ItemExistsButIsWrongType -f $Path)
            }
        }
    }
}

Function Open-ZipFile
{
    param($Path)
    add-type -assemblyname System.IO.Compression.FileSystem
    $nameHash = @{}
    try
    {
        $fileHandle = ([System.IO.Compression.ZipFile]::OpenRead($Path))
        $entries = $fileHandle.Entries
    }    
    catch
    {
        Throw-TerminatingError ($LocalizedData.ErrorOpeningArchiveFile -f $Path) $_
    }
    
    $entries | %{$nameHash[$_.FullName] = $_}
    return $entries, $nameHash, $fileHandle
}

# The Set-TargetResource cmdlet is used to unpack or remove a zip file to a particular directory
function Set-TargetResource 
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    param
    (
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,
        
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Destination,
        
        [ValidateSet("Present", "Absent")]
        [string] $Ensure = "Present",
        
        [boolean] $Validate = $false,
        
        [ValidateSet("", "SHA-1", "SHA-256", "SHA-512", "CreatedDate", "ModifiedDate")]
        [string] $Checksum,
        
        [boolean] $Force = $false
    )
    
    $ErrorActionPreference = "Stop"
    Assert-ValidStandardArgs $Path $Destination $Validate $Checksum
    $Checksum = Normalize-Checksum $Validate $Checksum
    Write-Verbose $LocalizedData.ConfigurationStarted
    
    if(-not (Test-Path $Destination))
    {
        mkdir $Destination | Out-Null
    }
    
    $cacheObj = Get-CacheEntry $Path $Destination
    $sourceLastWriteTime = (Get-Item $Path).LastWriteTime
    $cacheUpToDate = $cacheObj -and $cacheObj.SourceLastWriteTime -and $cacheObj.SourceLastWriteTime -eq $sourceLastWriteTime
    $file = $null
    $nameToEntry = @{}
    try
    {
        if(-not $cacheUpToDate)
        {
            $entries, $nameToEntry, $file = Open-ZipFile $Path
            Update-Cache $cacheObj $entries $Checksum $sourceLastWriteTime
        }
        
        $entries = $cacheObj.Entries
        if($Ensure -eq "Absent")
        {
            $directories = new-object system.collections.generic.hashset[string]
            foreach($entry in $entries)
            {
                $isDir = $false
                if($entry.FullName.EndsWith("\"))
                {
                    $isDir = $true
                    $directories.Add((Split-Path -Leaf $entry)) | Out-Null
                }
                
                $parent = $entry.FullName
                while(($parent = (Split-Path $parent))) { $directories.Add($parent) | Out-Null }
                
                if($isDir)
                {
                    #Directory removal is handled as its own pass, see note and code after this loop
                    continue
                }
                
                $existing = Join-Path $Destination $entry.FullName
                $item = Get-Item $existing -EA SilentlyContinue
                if(-not $item)
                {
                    continue
                }
                
                 #Possible for a folder to have been replaced by a directory of the same name, in which case we must leave it alone
                $type = $item.GetType()
                if($type -ne [System.IO.FileInfo])
                {
                    continue
                }
                
                if(-not $Checksum -and $PSCmdlet.ShouldProcess(($LocalizedData.RemoveFile -f $existing), $null, $null))
                {
                    Trace-Message "Removing $existing"
                    rm $existing
                    continue
                }
                
                $Checksum = $Checksum.ToLower()
                if($Checksum.StartsWith("sha"))
                {
                    if((Compare-FileToEntry $existing $entry $Checksum) -and $PSCmdlet.ShouldProcess(($LocalizedData.RemoveFile -f $existing), $null, $null))
                    {
                        Trace-Message "Hashes of existing and zip files match, removing"
                        rm $existing
                    }
                    else
                    {
                        Trace-Message "Hash did not match, file has been modified since it was extracted. Leaving"
                    }
                }
                else
                {
                    $date = Get-RelevantChecksumTimestamp $item $Checksum
                    if($date.Equals($entry.LastWriteTime.DateTime) -and $PSCmdlet.ShouldProcess(($LocalizedData.RemoveFile -f $existing), $null, $null))
                    {
                        Trace-Message "In Set-TargetResource: $existing exists and the selected timestamp ($Checksum) matched, removing"
                        rm $existing
                    }
                    else
                    {
                        Trace-Message "In Set-TargetResource: $existing exists and the selected timestamp ($Checksum) did not match, leaving"
                    }
                }
            }
            
            #Hashset was useful for dropping dupes in an efficient manner, but it can mess with ordering
            #Sort according to current culture (directory names can be localized, obviously)
            #Reverse so we hit children before parents
            $directories = [system.linq.enumerable]::ToList($directories)
            $directories.Sort([System.StringComparer]::InvariantCultureIgnoreCase)
            $directories.Reverse()
            foreach($directory in $directories)
            {
                Trace-Message "Examining $directory to see if it should be removed"
                $existing = Join-Path $Destination $directory
                $item = Get-Item $existing -EA SilentlyContinue
                if($item -and $item.GetType() -eq [System.IO.DirectoryInfo] -and $item.GetFiles().Count -eq 0 -and $item.GetDirectories().Count -eq 0 `
                     -and $PSCmdlet.ShouldProcess(($LocalizedData.RemoveDirectory -f $existing), $null, $null))
                {
                    Trace-Message "$existing appears to be an empty directory. Removing it"
                    rmdir $existing
                }
            }
            
            Write-Verbose ($LocalizedData.PackageUninstalled -f $Path,$Destination)
            Write-Verbose $LocalizedData.ConfigurationFinished
            return
        }
        
        Ensure-Directory $Destination
        foreach($entry in $entries)
        {
            $dest = join-path $Destination $entry.FullName
            if($dest.EndsWith('\')) #Directory
            {
                Ensure-Directory $dest.TrimEnd("\") #Some cmdlets have problems with trailing char
                continue
            }
            
            $item = Get-Item $dest -EA SilentlyContinue
            if($item)
            {
                if($item.GetType() -eq [System.IO.FileInfo])
                {
                    if(-not $Checksum)
                    {
                        #It exists. The user didn't specify -Validate, so that's good enough for us
                        continue
                    }
                    
                    if($Checksum.StartsWith("sha"))
                    {
                        if($item.LastWriteTime.Equals($entry.ExistingTimestamp))
                        {
                            Trace-Message "LastWriteTime of $dest matches what we have on record, not re-examining $checksum"
                        }
                        else
                        {
                            $identical = Compare-FileToEntry $dest $entry $Checksum
                            
                            if($identical)
                            {
                                Trace-Message "Found a file at $dest where we were going to place one and hash matched. Continuing"
                                $entry.ExistingItemTimestamp = $item.LastWriteTime
                                continue
                            }
                            else
                            {
                                if($Force)
                                {
                                    Trace-Message "Found a file at $dest where we were going to place one and hash didn't match. It will be overwritten"
                                }
                                else
                                {
                                    Trace-Message "Found a file at $dest where we were going to place one and does not match the source, but Force was not specified. Erroring"
                                    Throw-TerminatingError ($LocalizedData.ItemExistsButIsIncorrect -f $dest)
                                }
                            }
                        }
                    }
                    else
                    {
                        $date = Get-RelevantChecksumTimestamp $item $Checksum
                        if($date.Equals($entry.LastWriteTime.DateTime))
                        {
                            Trace-Message "In Set-TargetResource: $dest exists and the selected timestamp ($Checksum) matched, will leave it"
                            continue
                        }
                        else
                        {
                            if($Force)
                            {
                                Trace-Message "In Set-TargetResource: $dest exists and the selected timestamp ($Checksum) did not match. Force was specified, we will overwrite"
                            }
                            else
                            {
                                Trace-Message "Found a file at $dest and timestamp ($Checksum) does not match the source, but Force was not specified. Erroring"
                                Throw-TerminatingError ($LocalizedData.ItemExistsButIsIncorrect -f $dest)
                            }
                        }
                    }
                }
                else
                {
                    if($Force)
                    {
                        Trace-Message "Found a directory at $dest where a file should be. Removing"
                        if($PSCmdlet.ShouldProcess(($LocalizedData.RemoveDirectory -f $dest), $null, $null))
                        {
                            rmdir -Recurse -Force $dest
                        }
                    }
                    else
                    {
                        Trace-Message "Found a directory at $dest where a file should be and Force was not specified. Erroring."
                        Throw-TerminatingError ($LocalizedData.ItemExistsButIsWrongType -f $dest)
                    }
                }
            }
            
            $parent = Split-Path $dest
            if(-not (Test-Path $parent) -and $PSCmdlet.ShouldProcess(($LocalizedData.MakeDirectory -f $parent), $null, $null))
            {
                #TODO: This is an edge case we need to revisit. We should be correctly handling wrong file types along
                #the directory path if they occur within the archive, but they don't have to. Simple tests demonstrate that
                #the Zip format allows you to have the file within a folder without explicitly having an entry for the folder
                #This solution will fail in such a case IF anything along the path is of the wrong type (e.g. file in a place
                #we expect a directory to be)
                mkdir $parent | Out-Null
            }
            
            if($PSCmdlet.ShouldProcess(($LocalizedData.UnzipFile -f $dest), $null, $null))
            {
                #If we get here we can safely blow away anything we find.
                $null, $nameToEntry, $file = Open-ZipFile $Path
                $stream = $null
                $outStream = $null
                try
                {
                    Trace-Message "Writing to file $dest"
                    $stream = $nameToEntry[$entry.FullName].Open()
                    $outStream = New-Object System.IO.FileStream $dest, "Create"
                    $stream.CopyTo($outStream)
                }
                catch
                {
                    Throw-TerminatingError ($LocalizedData.ErrorCopyingToOutstream -f $dest) $_
                }
                finally
                {
                    if($stream -ne $null)
                    {
                        $stream.Dispose()
                    }
                    
                    if($outStream -ne $null)
                    {
                        $outStream.Dispose()
                    }
                }
                
                $fileInfo = New-Object System.IO.FileInfo $dest
                $entry.ExistingItemTimestamp = $fileInfo.LastWriteTime = $fileInfo.LastAccessTime = $fileInfo.CreationTime = $entry.LastWriteTime.DateTime
            }
        }
    }
    finally
    {
        if($file)
        {
            $file.Dispose()
        }
    }
    
    Set-CacheEntry -InputObject $cacheObj $Path $Destination
    Write-Verbose ($LocalizedData.PackageInstalled -f $Path,$Destination)
    Write-Verbose $LocalizedData.ConfigurationFinished
}

# The Get-TargetResource cmdlet is used to fetch the object
function Get-TargetResource
{
    param
    (
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,
        
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Destination,
        
        [boolean] $Validate = $false,
        
        [ValidateSet("", "SHA-1", "SHA-256", "SHA-512", "CreatedDate", "ModifiedDate")]
        [string] $Checksum
    )
    
    $exists = Test-TargetResource -Path $Path -Destination $Destination -Validate $Validate -Checksum $Checksum
    
    $stringResult = "Absent"
    if($exists)
    {
        $stringResult = "Present"
    }
    
    @{
        Ensure = $stringResult;
        Path = $Path;
        Destination = $Destination;
    }
}

Export-ModuleMember -function Get-TargetResource, Set-TargetResource, Test-TargetResource
