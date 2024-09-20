#####################################################
# HelloID-connector
# PowerShell V2 (Delete)
#####################################################

# region Development
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
			token = "cc9d3b512dc667075c87254e4f7d06bc03d6419a"
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
    $splatParams = @{
        Uri     = "$baseUrl/api/v$ApiVersion/organisation/people/?$($CorrelationField)=$($CorrelationValue)&sync_source=HelloID"
        Method  = 'GET'
        Headers = $Headers
    }
    $responseGet = Invoke-CrisisSuiteRestMethod @splatParams

    if ([string]::IsNullOrEmpty($responseGet) -or $responseGet.count -eq 0) {
        Write-Output $null
    }
    elseif ($responseGet.count -eq 1) {
        write-output $responseGet.results
    }
    else {
        $outputContext.AuditLogs.Add([PSCustomObject]@{
                Message = "Multiple [$($responseGet.Count)] people found with $CorrelationField =  $($CorrelationValue)"
                IsError = $true
            })
    }
}

function Delete-Person {
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
        $PersonId
    )

    Write-Verbose "Deleting person"

    $splatParams = @{
        Uri     = "$BaseUrl/api/v$ApiVersion/organisation/people/$PersonId/"
        Method  = 'DELETE'
        Headers = $Headers
    }
    Invoke-CrisisSuiteRestMethod @splatParams
    Write-Verbose "Person with ID [$PersonId] successfully deleted"
}
#endregion functions

#region correlation
try {
    $action = 'Process'

    $splatParamsAuthorizationHeaders = @{
        Token = $actionContext.Configuration.token
    }
    $authHeaders = Set-AuthorizationHeaders @splatParamsAuthorizationHeaders

    if ($actionContext.CorrelationConfiguration.Enabled) {
        $correlationField = $actionContext.CorrelationConfiguration.accountField
        $correlationValue = $actionContext.CorrelationConfiguration.accountFieldValue

        if ([string]::IsNullOrEmpty($correlationField) -or [string]::IsNullOrEmpty($correlationValue)) {
            Throw "Correlation is enabled but not configured correctly."
        }

        $splatParamsPerson = @{
            correlationValue = $correlationValue
            correlationField = $correlationField
            Headers          = $authHeaders
            BaseUrl          = $actionContext.Configuration.baseUrl
			ApiVersion       = $actionContext.Configuration.apiVersion
        }
        $Person = Get-PersonByCorrelationAttribute @splatParamsPerson
    }
    else {
        Throw "Configuration of correlation is mandatory."
    }
#endregion correlation

#region Calculate action
    if (-Not([string]::IsNullOrEmpty($Person))) {
        $action = 'Delete'
    }
    else {
        Throw "Person not found, cannot perform delete."
    }

    Write-Verbose "Check if current person can be found. Result: $action"
#endregion Calculate action

    switch ($action) {
        'Delete' {
            $personId = $Person.id

            Write-Verbose "Deleting person with id [$($personId)]"

            $splatParamsPersonDelete = @{
                Headers   = $authHeaders
                BaseUrl   = $actionContext.Configuration.baseUrl
                ApiVersion= $actionContext.Configuration.apiVersion
				PersonId  = $personId
            }

            if (-Not($actionContext.DryRun -eq $true)) {
                Delete-Person @splatParamsPersonDelete

                Write-Information "Person with id [$($personId)] successfully deleted"

                $outputContext.AuditLogs.Add([PSCustomObject]@{
                        Message = "Person with id [$($personId)] successfully deleted"
                        IsError = $false
                    })
            }
            else {
                Write-Warning "DryRun would delete person with ID [$($personId)]"
            }

            $outputContext.AccountReference = $personId
            $outputContext.Data = $null

            break
        }
    }
}
catch {
    $ex = $PSItem
    $errorMessage = if ($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException' -or $ex.Exception.GetType().FullName -eq 'System.Net.WebException') {
        "Could not $action person. Error: $($ex.ErrorDetails.Message)"
    } else {
        "Could not $action person. Error: $($ex.Exception.Message) $($ex.ScriptStackTrace)"
    }

    if (-Not($ex.Exception.Message -eq 'Error(s) occured while looking up required values')) {
        $outputContext.AuditLogs.Add([PSCustomObject]@{
                Message = $errorMessage
                IsError = $true
            })
    }
}
finally {
    if ($outputContext.AuditLogs.IsError -notContains $true) {
        $outputContext.Success = $true
    }

    if ([String]::IsNullOrEmpty($outputContext.AccountReference) -and $actionContext.DryRun -eq $true) {
        $outputContext.AccountReference = "DryRun: Currently not available"
    }
}

# TODO: REMOVE BEFORE FLIGHT
$outputContext | Out-String | Write-Verbose