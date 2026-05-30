# .ps-rule/Local.Rule.ps1
# =============================================================================
# Custom PSRule rules for the Azure Reference Architecture portfolio.
# These supplement PSRule.Rules.Azure with portfolio-specific governance checks.
#
# Rules are automatically discovered by PSRule when this file is inside .ps-rule/.
# =============================================================================

# -----------------------------------------------------------------------------
# Local.Tags.NoMissingParameterDefaults
#
# Fails when any ARM template tag parameter has a default value that contains
# the word "Missing". This catches the case where PSRule cannot fully resolve
# .bicepparam values and the default falls through instead.
#
# Target type: Microsoft.Resources/deployments (the compiled ARM template root).
# -----------------------------------------------------------------------------
Rule 'Local.Tags.NoMissingParameterDefaults' -Type 'Microsoft.Resources/deployments' {
    $template = $TargetObject.properties?.template
    if ($null -eq $template -or $null -eq $template.parameters) {
        $Assert.Create($true, '')
        return
    }

    $bad = @(
        $template.parameters.PSObject.Properties |
        Where-Object { $_.Name -imatch '^tag' } |
        Where-Object {
            $_.Value.defaultValue -is [string] -and
            $_.Value.defaultValue -imatch '\bMissing\b'
        } |
        ForEach-Object { "$($_.Name)='$($_.Value.defaultValue)'" }
    )

    $Assert.Create(
        $bad.Count -eq 0,
        "Tag parameter(s) use a 'Missing' placeholder as their default value. " +
        "Set explicit values for all tag params in main.bicepparam. " +
        "Affected: $($bad -join '; ')"
    )
}

# -----------------------------------------------------------------------------
# Local.Tags.NoMissingTagValues
#
# Fails when any resource tag value contains the word "Missing".
# This rule catches resolved values - it is effective when PSRule.Rules.Azure
# expands .bicepparam parameters (AZURE_BICEP_PARAMS_FILE_EXPANSION: true).
#
# Target type: all resource types (*).
# -----------------------------------------------------------------------------
Rule 'Local.Tags.NoMissingTagValues' -Type '*' {
    $bad = @()
    if ($null -ne $TargetObject.tags) {
        $bad = @(
            $TargetObject.tags.PSObject.Properties |
            Where-Object { $_.Value -is [string] -and $_.Value -imatch '\bMissing\b' } |
            ForEach-Object { "$($_.Name)='$($_.Value)'" }
        )
    }

    $Assert.Create(
        $bad.Count -eq 0,
        "Resource '$($TargetObject.name)' has tag value(s) containing the placeholder 'Missing'. " +
        "Update main.bicepparam with explicit values. " +
        "Affected: $($bad -join '; ')"
    )
}

