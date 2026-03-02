#!/bin/bash
#
# create-project-group.sh
# Bash/Azure CLI version of PowerShell script for Linux environments
#
# Usage:
#   ./create-project-group.sh "marketing-chatbot" "alice@contoso.com" "bob@contoso.com,carol@contoso.com"
#

set -e

PROJECT_NAME=$1
DEV_LEAD_EMAIL=$2
TEAM_MEMBERS=$3

if [ -z "$PROJECT_NAME" ] || [ -z "$DEV_LEAD_EMAIL" ]; then
    echo "Usage: $0 <project-name> <dev-lead-email> [team-members-comma-separated]"
    exit 1
fi

echo "========================================="
echo "Creating Entra ID Group for Project"
echo "========================================="

# Check Azure CLI login
if ! az account show &> /dev/null; then
    echo "Logging in to Azure..."
    az login
fi

# Resolve Dev Lead Object ID
echo "Resolving Dev Lead: $DEV_LEAD_EMAIL"
DEV_LEAD_OBJECT_ID=$(az ad user list \
    --filter "mail eq '$DEV_LEAD_EMAIL' or userPrincipalName eq '$DEV_LEAD_EMAIL'" \
    --query "[0].id" -o tsv)

if [ -z "$DEV_LEAD_OBJECT_ID" ]; then
    echo "❌ Dev Lead not found: $DEV_LEAD_EMAIL"
    exit 1
fi

echo "✅ Dev Lead found: $DEV_LEAD_OBJECT_ID"

# Create group
GROUP_NAME="AI-Project-$PROJECT_NAME"
GROUP_NICKNAME=$(echo "$GROUP_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]')

echo "Creating group: $GROUP_NAME"

GROUP_ID=$(az ad group create \
    --display-name "$GROUP_NAME" \
    --mail-nickname "$GROUP_NICKNAME" \
    --description "Security group for AI Foundry project: $PROJECT_NAME" \
    --query "id" -o tsv)

echo "✅ Group created: $GROUP_ID"

# Add Dev Lead as owner
echo "Adding Dev Lead as owner..."
az ad group owner add \
    --group "$GROUP_ID" \
    --owner-object-id "$DEV_LEAD_OBJECT_ID"

echo "✅ Owner added"

# Add Dev Lead as member
echo "Adding Dev Lead as member..."
az ad group member add \
    --group "$GROUP_ID" \
    --member-id "$DEV_LEAD_OBJECT_ID"

echo "✅ Member added"

# Add team members
if [ -n "$TEAM_MEMBERS" ]; then
    IFS=',' read -ra MEMBERS <<< "$TEAM_MEMBERS"
    echo "Adding ${#MEMBERS[@]} team members..."
    
    for MEMBER_EMAIL in "${MEMBERS[@]}"; do
        MEMBER_ID=$(az ad user list \
            --filter "mail eq '$MEMBER_EMAIL' or userPrincipalName eq '$MEMBER_EMAIL'" \
            --query "[0].id" -o tsv)
        
        if [ -n "$MEMBER_ID" ]; then
            az ad group member add \
                --group "$GROUP_ID" \
                --member-id "$MEMBER_ID"
            echo "  ✅ Added: $MEMBER_EMAIL"
        else
            echo "  ⚠️ User not found: $MEMBER_EMAIL"
        fi
    done
fi

# Output results
echo ""
echo "========================================="
echo "✅ Group Created Successfully"
echo "========================================="
echo "Group Name:   $GROUP_NAME"
echo "Group ID:     $GROUP_ID"
echo "Dev Lead ID:  $DEV_LEAD_OBJECT_ID"
echo ""
echo "Next Steps:"
echo "1. Assign group to Foundry project RBAC"
echo "2. Share group ID with ServiceNow automation"
echo "3. Dev Lead can manage members via Azure Portal"

# Save to JSON for automation
cat > "group-$PROJECT_NAME.json" <<EOF
{
  "groupId": "$GROUP_ID",
  "groupName": "$GROUP_NAME",
  "devLeadObjectId": "$DEV_LEAD_OBJECT_ID",
  "projectName": "$PROJECT_NAME"
}
EOF

echo ""
echo "📄 Details saved to: group-$PROJECT_NAME.json"
