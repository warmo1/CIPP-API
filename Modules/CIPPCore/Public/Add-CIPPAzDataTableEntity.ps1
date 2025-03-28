function Add-CIPPAzDataTableEntity {
    [CmdletBinding(DefaultParameterSetName = 'OperationType')]
    param(
        $Context,
        $Entity,
        [switch]$CreateTableIfNotExists,

        [Parameter(ParameterSetName = 'Force')]
        [switch]$Force,

        [Parameter(ParameterSetName = 'OperationType')]
        [ValidateSet('Add', 'UpsertMerge', 'UpsertReplace')]
        [string]$OperationType = 'Add'
    )

    $Parameters = @{
        Context                = $Context
        CreateTableIfNotExists = $CreateTableIfNotExists
    }
    if ($PSCmdlet.ParameterSetName -eq 'Force') {
        $Parameters.Force = $Force
    } else {
        $Parameters.OperationType = $OperationType
    }

    $MaxRowSize = 500000 - 100 # Maximum size of an entity
    $MaxSize = 30kb # Maximum size of a property value

    foreach ($SingleEnt in @($Entity)) {
        try {
            if ($null -eq $SingleEnt.PartitionKey -or $null -eq $SingleEnt.RowKey) {
                throw 'PartitionKey or RowKey is null'
            }
            Add-AzDataTableEntity @Parameters -Entity $SingleEnt -ErrorAction Stop
        } catch [System.Exception] {
            if ($_.Exception.ErrorCode -eq 'PropertyValueTooLarge' -or $_.Exception.ErrorCode -eq 'EntityTooLarge' -or $_.Exception.ErrorCode -eq 'RequestBodyTooLarge') {
                try {
                    Write-Host 'Entity is too large. Splitting entity into multiple parts.'
                    #Write-Information ($SingleEnt | ConvertTo-Json)
                    $largePropertyNames = [System.Collections.Generic.List[string]]::new()
                    $entitySize = 0

                    # Convert $SingleEnt to hashtable if it is a PSObject
                    if ($SingleEnt -is [System.Management.Automation.PSCustomObject]) {
                        $SingleEnt = $SingleEnt | ConvertTo-Json -Depth 100 -Compress | ConvertFrom-Json -AsHashtable
                    }

                    foreach ($key in $SingleEnt.Keys) {
                        $propertySize = [System.Text.Encoding]::UTF8.GetByteCount($SingleEnt[$key].ToString())
                        $entitySize = $entitySize + $propertySize
                        if ($propertySize -gt $MaxSize) {
                            $largePropertyNames.Add($key)
                        }
                    }

                    if (($largePropertyNames | Measure-Object).Count -gt 0) {
                        $splitInfoList = [System.Collections.Generic.List[object]]::new()
                        foreach ($largePropertyName in $largePropertyNames) {
                            $dataString = $SingleEnt[$largePropertyName]
                            $splitCount = [math]::Ceiling($dataString.Length / $MaxSize)
                            $splitData = [System.Collections.Generic.List[object]]::new()
                            for ($i = 0; $i -lt $splitCount; $i++) {
                                $start = $i * $MaxSize
                                $splitData.Add($dataString.Substring($start, [Math]::Min($MaxSize, $dataString.Length - $start))) > $null
                            }
                            $splitDataCount = ($splitData | Measure-Object).Count
                            $splitPropertyNames = [System.Collections.Generic.List[object]]::new()
                            for ($i = 0; $i -lt $splitDataCount; $i++) {
                                $splitPropertyNames.Add("${largePropertyName}_Part$i")
                            }

                            $splitInfo = @{
                                OriginalHeader = $largePropertyName
                                SplitHeaders   = $splitPropertyNames
                            }
                            $splitInfoList.Add($splitInfo)
                            $SingleEnt.Remove($largePropertyName)

                            for ($i = 0; $i -lt $splitDataCount; $i++) {
                                $SingleEnt[$splitPropertyNames[$i]] = $splitData[$i]
                            }
                        }

                        $SingleEnt['SplitOverProps'] = ($splitInfoList | ConvertTo-Json -Compress).ToString()
                    }

                    # Check if the entity is still too large
                    $entitySize = [System.Text.Encoding]::UTF8.GetByteCount($($SingleEnt | ConvertTo-Json -Compress))
                    if ($entitySize -gt $MaxRowSize) {
                        $rows = [System.Collections.Generic.List[object]]::new()
                        $originalPartitionKey = $SingleEnt.PartitionKey
                        $originalRowKey = $SingleEnt.RowKey
                        $entityIndex = 0

                        while ($entitySize -gt $MaxRowSize) {
                            Write-Information "Entity size is $entitySize. Splitting entity into multiple parts."
                            $newEntity = @{}
                            $newEntity['PartitionKey'] = $originalPartitionKey
                            if ($entityIndex -eq 0) {
                                $newEntity['RowKey'] = $originalRowKey
                            } else {
                                $newEntity['RowKey'] = "$($originalRowKey)-part$entityIndex"
                            }
                            $newEntity['OriginalEntityId'] = $originalRowKey
                            $newEntity['PartIndex'] = $entityIndex
                            $entityIndex++

                            $propertiesToRemove = [System.Collections.Generic.List[object]]::new()
                            foreach ($key in $SingleEnt.Keys) {
                                $newEntitySize = [System.Text.Encoding]::UTF8.GetByteCount($($newEntity | ConvertTo-Json -Compress))
                                if ($newEntitySize -lt $MaxRowSize) {
                                    $propertySize = [System.Text.Encoding]::UTF8.GetByteCount($SingleEnt[$key].ToString())
                                    if ($propertySize -gt $MaxRowSize) {
                                        $dataString = $SingleEnt[$key]
                                        $splitCount = [math]::Ceiling($dataString.Length / $MaxSize)
                                        $splitData = [System.Collections.Generic.List[object]]::new()
                                        for ($i = 0; $i -lt $splitCount; $i++) {
                                            $start = $i * $MaxSize
                                            $splitData.Add($dataString.Substring($start, [Math]::Min($MaxSize, $dataString.Length - $start))) > $null
                                        }

                                        $splitPropertyNames = [System.Collections.Generic.List[object]]::new()
                                        for ($i = 0; $i -lt $splitData.Count; $i++) {
                                            $splitPropertyNames.Add("${key}_Part$i")
                                        }

                                        for ($i = 0; $i -lt $splitData.Count; $i++) {
                                            $newEntity[$splitPropertyNames[$i]] = $splitData[$i]
                                        }
                                    } else {
                                        $newEntity[$key] = $SingleEnt[$key]
                                    }
                                    $propertiesToRemove.Add($key)
                                }
                            }

                            foreach ($prop in $propertiesToRemove) {
                                $SingleEnt.Remove($prop)
                            }

                            $rows.Add($newEntity)
                            $entitySize = [System.Text.Encoding]::UTF8.GetByteCount($($SingleEnt | ConvertTo-Json -Compress))
                        }

                        if (($SingleEnt | Measure-Object).Count -gt 0) {
                            $SingleEnt['RowKey'] = "$($originalRowKey)-part$entityIndex"
                            $SingleEnt['OriginalEntityId'] = $originalRowKey
                            $SingleEnt['PartIndex'] = $entityIndex
                            $SingleEnt['PartitionKey'] = $originalPartitionKey

                            $rows.Add($SingleEnt)
                        }

                        foreach ($row in $rows) {
                            Write-Information "current entity is $($row.RowKey) with $($row.PartitionKey). Our size is $([System.Text.Encoding]::UTF8.GetByteCount($($row | ConvertTo-Json -Compress)))"
                            $NewRow = ([PSCustomObject]$row) | Select-Object * -ExcludeProperty Timestamp
                            Add-AzDataTableEntity @Parameters -Entity $NewRow
                        }
                    } else {
                        $NewEnt = ([PSCustomObject]$SingleEnt) | Select-Object * -ExcludeProperty Timestamp
                        Add-AzDataTableEntity @Parameters -Entity $NewEnt
                    }

                } catch {
                    $ErrorMessage = Get-NormalizedError -Message $_.Exception.Message
                    Write-Warning ('AzBobbyTables Error')
                    Write-Information ($SingleEnt | ConvertTo-Json)
                    throw "Error processing entity: $ErrorMessage Linenumber: $($_.InvocationInfo.ScriptLineNumber)"
                }
            } else {
                Write-Information "THE ERROR IS $($_.Exception.message). The size of the entity is $entitySize."
                throw $_
            }
        }
    }
}
