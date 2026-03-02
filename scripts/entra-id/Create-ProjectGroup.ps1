#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Creates an Entra ID security group for a Foundry project team.

.DESCRIPTION
    Automates the creation of an Entra ID group with the Dev Lead as owner.
    Used by ServiceNow automation when provisioning new AI projects.

.PARAMETER ProjectName
    Name of the AI Foundry project (e.g., "marketing-chatbot")

.PARAMETER DevLeadEmail
    Email address of the developer who will own the group

.PARAMETER TeamMembers
    Array of email addresses for initial team members

.EXAMPLE
    .\Create-ProjectGroup.ps1 -ProjectName "marketing-chatbot" `
        -DevLeadEmail "alice@contoso.com" `
        -TeamMembers @("bob@contoso.com", "carol@contoso.com")

.NOTES
    Requires: Az.Accounts, Microsoft.Graph PowerShell modules
    Permissions: Group.ReadWrite.All, User.Read.All
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$ProjectName,
    
    [Parameter(Mandatory = $true)]
    [string]$DevLeadEmail,
    
    [Parameter(Mandatory = $false)]
    [string[]]$TeamMembers = @()
)

# Import required modules
Import-Module Microsoft.Graph.Groups
Import-Module Microsoft.Graph.Users

# Connect to Microsoft Graph
Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
Connect-MgGraph -Scopes "Group.ReadWrite.All", "User.Read.All"

# Resolve Dev Lead object ID
Write-Host "Resolving Dev Lead: $DevLeadEmail" -ForegroundColor Cyan
$devLead = Get-MgUser -Filter "mail eq '$DevLeadEmail' or userPrincipalName eq '$DevLeadEmail'"

if (-not $devLead) {
    Write-Error "Dev Lead not found: $DevLeadEmail"
    exit 1
}

Write-Host "Dev Lead found: $($devLead.DisplayName) ($($devLead.Id))" -ForegroundColor Green

# Create group
$groupName = "AI-Project-$ProjectName"
$groupDescription = "Security group for AI Foundry project: $ProjectName"

Write-Host "Creating Entra ID group: $groupName" -ForegroundColor Cyan

$groupParams = @{
    DisplayName = $groupName
    Description = $groupDescription
    MailEnabled = $false
    SecurityEnabled = $true
    MailNickname = $groupName.ToLower() -replace '[^a-z0-9]', ''
    GroupTypes = @()
}

try {
    $group = New-MgGroup -BodyParameter $groupParams
    Write-Host "✅ Group created: $($group.Id)" -ForegroundColor Green
}
catch {
    Write-Error "Failed to create group: $_"
    exit 1
}

# Add Dev Lead as owner
Write-Host "Adding Dev Lead as group owner..." -ForegroundColor Cyan
$ownerParams = @{
    "@odata.id" = "https://graph.microsoft.com/v1.0/users/$($devLead.Id)"
}

New-MgGroupOwner -GroupId $group.Id -BodyParameter $ownerParams
Write-Host "✅ Dev Lead added as owner" -ForegroundColor Green

# Add Dev Lead as member
Write-Host "Adding Dev Lead as group member..." -ForegroundColor Cyan
$memberParams = @{
    "@odata.id" = "https://graph.microsoft.com/v1.0/users/$($devLead.Id)"
}

New-MgGroupMember -GroupId $group.Id -BodyParameter $memberParams
Write-Host "✅ Dev Lead added as member" -ForegroundColor Green

# Add team members
if ($TeamMembers.Count -gt 0) {
    Write-Host "Adding $($TeamMembers.Count) team members..." -ForegroundColor Cyan
    
    foreach ($memberEmail in $TeamMembers) {
        $user = Get-MgUser -Filter "mail eq '$memberEmail' or userPrincipalName eq '$memberEmail'"
        
        if ($user) {
            $memberParams = @{
                "@odata.id" = "https://graph.microsoft.com/v1.0/users/$($user.Id)"
            }
            
            New-MgGroupMember -GroupId $group.Id -BodyParameter $memberParams
            Write-Host "  ✅ Added: $($user.DisplayName)" -ForegroundColor Green
        }
        else {
            Write-Warning "  ⚠️ User not found: $memberEmail"
        }
    }
}

# Output results
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Group Created Successfully" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Group Name:   $groupName"
Write-Host "Group ID:     $($group.Id)"
Write-Host "Owner:        $($devLead.DisplayName)"
Write-Host "Members:      $($TeamMembers.Count + 1) total"
Write-Host "`nNext Steps:"
Write-Host "1. Assign group to Foundry project RBAC (Cognitive Services User)"
Write-Host "2. Share group ID with ServiceNow automation"
Write-Host "3. Dev Lead can manage members via Entra ID or Portal"

# Return group details as JSON for automation
$result = @{
    GroupId = $group.Id
    GroupName = $groupName
    DevLeadObjectId = $devLead.Id
    MemberCount = $TeamMembers.Count + 1
}

$result | ConvertTo-Json | Out-File -FilePath ".\group-$ProjectName.json"
Write-Host "`n📄 Details saved to: group-$ProjectName.json" -ForegroundColor Cyan

Disconnect-MgGraph
