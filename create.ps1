#####################################################
# HelloID-connector
# PowerShell V2
#####################################################

# region Development
# This bit is added to make testing of the code easier in development. It should
# not give issues in prod. But if it does, just remove this section.
[CmdletBinding()]
param()

if (-not $outputContext) {
	$outputContext = [PSCustomObject]@{
		Success = $false
		AuditLogs = [System.Collections.Generic.List[PSObject]]::new() # Dynamic list
		AccountReference = $null
		AccountCorrelated = $false
		Data = $null
	}
}

if (-not $actionContext) {
	$personData = @{
		external_reference = "1002"
		first_name = "Pietje"
		initials = "P.P."
		gender = "M"
		insertion = ""
		last_name = "Puk"
		communication_details = @(
			@{
				type = "E" 
				value = "pietje@puk.nl"
			}
		)
	}

	$actionContext = [PSCustomObject]@{
		Configuration = [PSCustomObject]@{
			token = "412d839521cac8a30e49d991b2f59a204e851967"
			apiVersion = "21"
			baseUrl = "http://localhost:8000"
		}
		CorrelationConfiguration = [PSCustomObject]@{
			Enabled = $true
			accountField = "external_reference"
			accountFieldValue = $personData["external_reference"]
		}
		DryRun = $false
		Data = $personData
	}
}
#endregion


#region functions
function Set-AuthorizationHeaders {
    param (
        [ValidateNotNullOrEmpty()]
        [string]
        $Token
    )
    # Set authentication headers
    $authHeaders = @{}
    $authHeaders["Authorization"] = "Token $Token"
    $authHeaders["Accept"] = "application/json; charset=utf-8"

    Write-Output $authHeaders
}

function Invoke-CrisisSuiteRestMethod {
    param (
        [ValidateNotNullOrEmpty()]
        [string]
        $Method,

        [ValidateNotNullOrEmpty()]
        [string]
        $Uri,

        [object]
        $Body,

        [string]
        $ContentType = 'application/json; charset=utf-8',

        [System.Collections.IDictionary]
        $Headers
    )
    process {
        try {
            $splatParams = @{
                Uri         = $Uri
                Headers     = $Headers
                Method      = $Method
                ContentType = $ContentType
            }

            if ($Body) {
                $splatParams['Body'] = [Text.Encoding]::UTF8.GetBytes($Body)
            }
            Invoke-RestMethod @splatParams -Verbose:$false
        }
        catch {
            Throw $_
        }
    }
}

function Get-PersonByCorrelationAttribute {
    param (
        [ValidateNotNullOrEmpty()]
        [string]
        $BaseUrl,

        [ValidateNotNullOrEmpty()]
        [string]
        $ApiVersion,

        [System.Collections.IDictionary]
        $Headers,

        [ValidateNotNullOrEmpty()]
        [Object]
        $CorrelationValue,

        [ValidateNotNullOrEmpty()]
        [String]
        $CorrelationField
    )

    # Lookup value is filled in, lookup value in CrisisSuite
    $splatParams = @{
        Uri     = "$baseUrl/api/v$ApiVersion/organisation/people/?$($CorrelationField)=$($CorrelationValue)&sync_source=HelloID"
        Method  = 'GET'
        Headers = $Headers
    }
    $responseGet = Invoke-CrisisSuiteRestMethod @splatParams

    # Check if only one result is returned
    if ([string]::IsNullOrEmpty($responseGet) -or $responseGet.count -eq 0) {
        # no results found
        Write-Output $null
    }
    elseif ($responseGet.count -eq 1) {
        # one record found, correlate, return user
        write-output $responseGet.results
    }
    else {
        # Multiple records found, correlation
        $outputContext.AuditLogs.Add([PSCustomObject]@{
                Message = "Multiple [$($responseGet.Count)] people found with $CorrelationField =  $($CorrelationValue)"
                IsError = $true
            })
    }
}

function New-Person {
    param (
        [ValidateNotNullOrEmpty()]
        [string]
        $BaseUrl,
		
        [ValidateNotNullOrEmpty()]
        [string]
        $ApiVersion,

        [System.Collections.IDictionary]
        $Headers,

        [ValidateNotNullOrEmpty()]
        [Object]
        $Data
    )

    Write-Verbose "Creating person"

	$Data.Add("sync_source", "HelloID")
	
    $splatParams = @{
        Uri     = "$BaseUrl/api/v$ApiVersion/organisation/people/"
        Method  = 'POST'
        Headers = $Headers
        Body    = $Data | ConvertTo-Json -Depth 5
    }
    $Person = Invoke-CrisisSuiteRestMethod @splatParams
    Write-Output $Person
}
#endregion functions

#region correlation
try {
    $action = 'Process'
    
    # Setup authentication headers
    $splatParamsAuthorizationHeaders = @{
        Token = $actionContext.Configuration.token
    }
    $authHeaders = Set-AuthorizationHeaders @splatParamsAuthorizationHeaders

    # Check if we should try to correlate the account
    if ($actionContext.CorrelationConfiguration.Enabled) {
        $correlationField = $actionContext.CorrelationConfiguration.accountField
        $correlationValue = $actionContext.CorrelationConfiguration.accountFieldValue

        if ([string]::IsNullOrEmpty($correlationField)) {
            Write-Warning "Correlation is enabled but not configured correctly."
            Throw "Correlation is enabled but not configured correctly."
        }

        if ([string]::IsNullOrEmpty($correlationValue)) {
            Write-Warning "The correlation value for [$correlationField] is empty. This is likely a scripting issue."
            Throw "The correlation value for [$correlationField] is empty. This is likely a scripting issue."
        }

        # get person
        $splatParamsPerson = @{
            correlationValue = $correlationValue
            correlationField = $correlationField
            Headers          = $authHeaders
            BaseUrl          = $actionContext.Configuration.baseUrl
			ApiVersion       = $actionContext.Configuration.apiVersion
            PersonType       = 'person'
        }
        $Person = Get-PersonByCorrelationAttribute @splatParamsPerson
    }
    else {
        Throw "Configuration of correlation is mandatory."
    }
    #endregion correlation
	
    #region Calulate action
    if (-Not([string]::IsNullOrEmpty($Person))) {
        $action = 'Correlate'
    }    
    else {
        $action = 'Create' 
    }
	
    Write-Verbose "Check if current person can be found. Result: $action"
    #endregion Calulate action

    switch ($action) {
        'Create' {   
		
			$data = $actionContext.Data
			
            #region write
            Write-Verbose "Creating person for:"
			$data | Out-String | Write-Verbose
			
            $splatParamsPersonNew = @{
                Headers = $authHeaders
                BaseUrl = $actionContext.Configuration.baseUrl
                ApiVersion = $actionContext.Configuration.apiVersion
				Data = $data
            }

            if (-Not($actionContext.DryRun -eq $true)) {
                $Person = New-Person @splatParamsPersonNew

                Write-Information "Person with id [$($Person.id)] and dynamicName [($($Person.dynamicName))] successfully created"

                $outputContext.AuditLogs.Add([PSCustomObject]@{
                        Message = "Person with id [$($Person.id)] and dynamicName [($($Person.dynamicName))] successfully created"
                        IsError = $false
                    })
            }
            else {
                Write-Warning "DryRun would create person. Person: $($data | Convertto-json)"
            }

            $outputContext.AccountReference = $Person.id
            $outputContext.Data = $Person


            break
            #endregion Write
        }
        
        'Correlate' {
            #region correlate
            Write-Information "Person with id [$($Person.id)] and dynamicName [$($Person.full_name)] successfully correlated on field [$($correlationField)] with value [$($correlationValue)]"

            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Action  = "CorrelateAccount"
                    Message = "Person with id [$($Person.id)] and name [($($Person.full_name))] successfully correlated on field [$($correlationField)] with value [$($correlationValue)]"
                    IsError = $false
                })

            $outputContext.AccountReference = $Person.id
            $outputContext.AccountCorrelated = $true
            $outputContext.Data = $Person
			Write-Verbose "Person: $($Person | Convertto-json)"
            
            break
            #endregion correlate
        }
    }
}
catch {
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {

        if (-Not [string]::IsNullOrEmpty($ex.ErrorDetails.Message)) {
            $errorMessage = "Could not $action person. Error: $($ex.ErrorDetails.Message)"
        }
        else {
            $errorMessage = "Could not $action person. Error: $($ex.Exception.Message)"
        }
    }
    else {
        $errorMessage = "Could not $action person. Error: $($ex.Exception.Message) $($ex.ScriptStackTrace)"
    }

    # Only log when there are no lookup values, as these generate their own audit message
    if (-Not($ex.Exception.Message -eq 'Error(s) occured while looking up required values')) {
        $outputContext.AuditLogs.Add([PSCustomObject]@{
                Message = $errorMessage
                IsError = $true
            })
    }
}
finally {
    # Check if auditLogs contains errors, if no errors are found, set success to true
    if ($outputContext.AuditLogs.IsError -notContains $true) {
        $outputContext.Success = $true
    }

    # Check if accountreference is set, if not set, set this with default value as this must contain a value
    if ([String]::IsNullOrEmpty($outputContext.AccountReference) -and $actionContext.DryRun -eq $true) {
        $outputContext.AccountReference = "DryRun: Currently not available"
    }
}

# TODO: REMOVE BEFORE FLIGHT
$outputContext | Out-String | Write-Verbose
