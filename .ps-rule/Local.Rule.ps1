# .ps-rule/Local.Rule.ps1
# =============================================================================
# Custom PSRule rules for the Azure Reference Architecture portfolio.
# These supplement PSRule.Rules.Azure with portfolio-specific governance checks.
#
# Rules are automatically discovered by PSRule when this file is inside .ps-rule/.
# =============================================================================

# -----------------------------------------------------------------------------
# Local.Tags.NoMissingTagValues
#
# Fails when any resolved resource tag value contains the word "Missing".
#
# When a tag parameter is omitted from main.bicepparam, Bicep falls back to the
# sentinel default (e.g. 'Missing Owner'). PSRule resolves those defaults during
# Bicep expansion (AZURE_BICEP_FILE_EXPANSION + AZURE_BICEP_PARAMS_FILE_EXPANSION)
# and this rule catches the resulting placeholder value on every tagged resource.
#
# -----------------------------------------------------------------------------
Rule 'Local.Tags.NoMissingTagValues' -Tag @{ 'Azure.WAF/pillar' = 'Reliability' } {
    # Skip objects that carry no tags (e.g. subnets, role assignments)
    if ($null -eq $TargetObject.tags) {
        $Assert.Create($true, '')
        return
    }

    $bad = @(
        $TargetObject.tags.PSObject.Properties |
        Where-Object { $_.Value -is [string] -and $_.Value -imatch '\bMissing\b' } |
        ForEach-Object { "$($_.Name)='$($_.Value)'" }
    )

    $Assert.Create(
        $bad.Count -eq 0,
        "Resource '$($TargetObject.name)' has tag value(s) containing the placeholder 'Missing'. " +
        "Set explicit values for all tag parameters in main.bicepparam. " +
        "Affected: $($bad -join '; ')"
    )
}

