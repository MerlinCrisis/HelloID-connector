# HelloID-connector
This connector has been developed by Merlin Software BV. Copyright 2024. All rights reserved.

Correlation configuration:

* Enable correlation
* Person correlation field: PersonContext.Person.ExternalId
* Account correlation field: external_reference

# Test script locally

Powershell command in order to test the script locally

```powershell
./create.ps1 -Verbose
./update.ps1 -Verbose
./delete.ps1 -Verbose
```