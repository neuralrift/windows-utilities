@{
    RootModule        = 'OneTask.psm1'
    ModuleVersion     = '1.0.0'   # always equal to $OneTaskVersion in t.ps1; test.ps1 checks it
    GUID              = 'b401ee40-772b-4128-ae4a-8b8481e179d8'
    Description       = 'one-task: a terminal todo that shows one task at a time (command t).'
    PowerShellVersion = '5.1'
    # Declared here so PowerShell finds t without loading the module, and loads it the first time t is typed
    FunctionsToExport = @('t')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
