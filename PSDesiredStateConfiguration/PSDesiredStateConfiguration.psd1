#
# Module manifest for module 'PowerShellDSC'
#
# Copyright="© Microsoft Corporation. All rights reserved."
#

@{

RootModule = 'Microsoft.Windows.DSC.CoreConfProviders.dll'

ModuleVersion = '1.0'

GUID = 'ced422f3-86a4-4841-9f80-a713eac9522a'

Author = 'Microsoft Corporation'

CompanyName = 'Microsoft Corporation'

Copyright="© Microsoft Corporation. All rights reserved."

Description = 'Module that implements the DSC extensions for PowerShell'

# PowerShellVersion = ''

# PowerShellHostName = ''

# PowerShellHostVersion = ''

# DotNetFrameworkVersion = ''

# CLRVersion = ''

# Processor architecture (None, X86, Amd64)
# ProcessorArchitecture = ''

# RequiredModules = @()

RequiredAssemblies = @("Microsoft.Management.Infrastructure",
                       "Microsoft.Windows.DSC.CoreConfProviders")

NestedModules = @('PSDesiredStateConfiguration.psm1', 'Get-DSCConfiguration.cdxml','Test-DSCConfiguration.cdxml','Get-DSCLocalConfigurationManager.cdxml','Restore-DSCConfiguration.cdxml')

# TypesToProcess = @()

FormatsToProcess = @('PSDesiredStateConfiguration.format.ps1xml')

FunctionsToExport = @('Configuration',
                      'Get-DscConfiguration',
                      'Test-DscConfiguration',
                      'Get-DscLocalConfigurationManager',
                      'Restore-DscConfiguration',
                      'New-DscCheckSum',
                      'Get-DscResource')

CmdletsToExport = @('Set-DscLocalConfigurationManager',
                      'Start-DscConfiguration')

VariablesToExport = '*'

AliasesToExport = @('sacfg',
                    'tcfg',
                    'gcfg',
                    'rtcfg',
                    'glcm',
                    'slcm')

# ModuleList = @()

# FileList = @()

# PrivateData = ''

HelpInfoURI = 'http://go.microsoft.com/fwlink/?LinkId=280237'

# DefaultCommandPrefix = ''

}

