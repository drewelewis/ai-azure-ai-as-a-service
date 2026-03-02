#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Assigns an Entra ID group to an Azure AI Foundry project with RBAC.

.DESCRIPTION
    Grants "Cognitive Services User" role to the group on the Foundry project.
    Used by ServiceNow automation after project provisioning.

.PARAMETER GroupId
    Entra ID group Object ID

.PARAMETER ProjectResourceId
    Full Azure resource ID of the Foundry project

.EXAMPLE
    .\Assign-GroupToProject.ps1 `
        -GroupId "12345678-1234-1234-1234-123456789012" `
        -ProjectResourceId "/subscriptions/.../providers/Microsoft.MachineLearningServices/workspaces/proj-marketing"

.NOTES
    Requires: Az.Accounts, Az.Resources modules
    Permissions: Contributor or User Access Administrator on project
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$GroupId,
    
    [Parameter(Mandatory = $true)]
    [string]$ProjectResourceId
)

# Import required modules
Import-Module Az.Accounts
Import-Module Az.Resources

# Connect to Azure
Write-Host "Connecting to Azure..." -ForegroundColor Cyan
Connect-AzAccount

# Get Cognitive Services User role definition
$roleName = "Cognitive Services User"
Write-Host "Looking up role: $roleName" -ForegroundColor Cyan

$roleDefinition = Get-AzRoleDefinition -Name $roleName

if (-not $roleDefinition) {
    Write-Error "Role not found: $roleName"
    exit 1
}

Write-Host "✅ Role found: $($roleDefinition.Id)" -ForegroundColor Green

# Check if assignment already exists
Write-Host "Checking for existing assignment..." -ForegroundColor Cyan
$existingAssignment = Get-AzRoleAssignment `
    -ObjectId $GroupId `
    -RoleDefinitionName $roleName `
    -Scope $ProjectResourceId `
    -ErrorAction SilentlyContinue

if ($existingAssignment) {
    Write-Host "⚠️ Assignment already exists. Skipping." -ForegroundColor Yellow
    exit 0
}

# Create role assignment
Write-Host "Creating role assignment..." -ForegroundColor Cyan
try {
    $assignment = New-AzRoleAssignment `
        -ObjectId $GroupId `
        -RoleDefinitionName $roleName `
        -Scope $ProjectResourceId
    
    Write-Host "✅ Role assigned successfully" -ForegroundColor Green
    Write-Host "Assignment ID: $($assignment.RoleAssignmentId)"
}
catch {
    Write-Error "Failed to create role assignment: $_"
    exit 1
}

# Output summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "RBAC Assignment Complete" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Group ID:     $GroupId"
Write-Host "Role:         $roleName"
Write-Host "Scope:        $ProjectResourceId"
Write-Host "`nGroup members can now access this Foundry project via:"
Write-Host "  • Azure AI SDK with DefaultAzureCredential()"
Write-Host "  • VS Code Azure AI Extension"
Write-Host "  • APIM gateway (if Entra ID auth enabled)"

Disconnect-AzAccount
