#!/usr/bin/env bash

# ============================================================
# Azure VM Bootstrapper
#
# AI-generated with ChatGPT (GPT-5.6 Luna)
# Generated: 2026-09-24
#
# Review before production use.
#
# Features:
#   - Prompts for VM name
#   - Retries invalid VM names
#   - Prompts for Linux username
#   - Prompts for password securely
#   - Retries invalid passwords
#   - Explains that password input is invisible
#   - Detects the active Azure subscription
#   - Detects subscription-specific allowed regions
#   - Validates VM deployments before creating them
#   - Tries multiple small VM sizes
#   - Handles quota/SKU/capacity failures
#   - Creates networking automatically
#   - Uses Standard SSD for the OS disk
#   - Cleans failed deployments asynchronously
#   - Removes previous resource groups created by this script
# ============================================================

set -u
set -o pipefail

VM_NAME=""
USERNAME=""
PASSWORD=""
PASSWORD_CONFIRM=""

# ------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------

cleanup() {
    unset PASSWORD PASSWORD_CONFIRM
}

handle_signal() {
    cleanup
    echo
    echo "[INFO] Script interrupted."
    exit 130
}

trap cleanup EXIT
trap handle_signal INT TERM

# ------------------------------------------------------------
# Output helpers
# ------------------------------------------------------------

die() {
    echo
    echo "[ERROR] $1" >&2
    exit 1
}

info() {
    echo "[+] $1"
}

warn() {
    echo "[!] $1"
}

success() {
    echo "[OK] $1"
}

# ------------------------------------------------------------
# Dependency checks
# ------------------------------------------------------------

command -v az >/dev/null 2>&1 \
    || die "Azure CLI is not installed."

# ------------------------------------------------------------
# Header
# ------------------------------------------------------------

echo
echo "============================================================"
echo " Azure VM Bootstrapper"
echo " AI-generated with ChatGPT (GPT-5.6 Luna)"
echo "============================================================"
echo

# ------------------------------------------------------------
# VM name
# ------------------------------------------------------------

while true; do
    if ! read -r -p "VM name: " VM_NAME; then
        die "Input was closed."
    fi

    if [ -z "$VM_NAME" ]; then
        warn "VM name cannot be empty."
        echo "Please try again."
        echo
        continue
    fi

    if ! [[ "$VM_NAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?$ ]]; then
        warn "VM name must be 1-64 characters and contain only letters, numbers and hyphens."
        echo "Please try again."
        echo
        continue
    fi

    if [ "${#VM_NAME}" -gt 50 ]; then
        warn "VM name must be 50 characters or fewer for this script."
        echo "Please try again."
        echo
        continue
    fi

    break
done

# ------------------------------------------------------------
# Linux username
# ------------------------------------------------------------

if ! read -r -p "Username: " USERNAME; then
    die "Input was closed."
fi

if [ -z "$USERNAME" ]; then
    die "Username cannot be empty."
fi

if ! [[ "$USERNAME" =~ ^[A-Za-z_][A-Za-z0-9_-]{0,31}$ ]]; then
    die "Username must be 1-32 characters and use letters, numbers, underscores or hyphens."
fi

# Azure/Linux reserved usernames.
case "$USERNAME" in
    1|123|a|actuser|adm|admin|admin1|admin2|administrator|aspnet|backup|console|david|guest|john|owner|root|server|sql|support|support_388945a0|sys|test|test1|test2|test3|user|user1|user2|user3|user4|user5|video)
        die "That username is reserved or restricted by Azure."
        ;;
esac

# ------------------------------------------------------------
# Password
# ------------------------------------------------------------
#
# Password input is hidden.
# Nothing will appear while typing, including asterisks.
# ------------------------------------------------------------

while true; do

    echo
    echo "Password input is invisible."
    echo "Nothing will appear in the terminal while you type."
    echo

    PASSWORD=""
    PASSWORD_CONFIRM=""

    if ! read -r -s -p "Password: " PASSWORD; then
        die "Password input was closed."
    fi
    printf '\n'

    if ! read -r -s -p "Confirm password: " PASSWORD_CONFIRM; then
        die "Password confirmation input was closed."
    fi
    printf '\n'

    if [ "$PASSWORD" != "$PASSWORD_CONFIRM" ]; then
        warn "Passwords do not match."
        echo "Please try again."
        continue
    fi

    PASSWORD_LENGTH=${#PASSWORD}

    if [ "$PASSWORD_LENGTH" -lt 12 ] || [ "$PASSWORD_LENGTH" -gt 123 ]; then
        warn "Password must be 12-123 characters."
        echo "Please try again."
        continue
    fi

    COMPLEXITY=0

    if [[ "$PASSWORD" =~ [a-z] ]]; then
        COMPLEXITY=$((COMPLEXITY + 1))
    fi

    if [[ "$PASSWORD" =~ [A-Z] ]]; then
        COMPLEXITY=$((COMPLEXITY + 1))
    fi

    if [[ "$PASSWORD" =~ [0-9] ]]; then
        COMPLEXITY=$((COMPLEXITY + 1))
    fi

    if [[ "$PASSWORD" =~ [^a-zA-Z0-9] ]]; then
        COMPLEXITY=$((COMPLEXITY + 1))
    fi

    if [ "$COMPLEXITY" -lt 3 ]; then
        warn "Password must contain at least 3 of:"
        echo "  - lowercase letter"
        echo "  - uppercase letter"
        echo "  - digit"
        echo "  - special character"
        echo
        echo "Please try again."
        continue
    fi

    break
done

# ------------------------------------------------------------
# Azure subscription
# ------------------------------------------------------------

echo

info "Checking active Azure subscription..."

if ! SUBSCRIPTION_ID=$(
    az account show \
        --query id \
        -o tsv \
        2>/dev/null
); then
    die "No active Azure subscription."
fi

if [ -z "$SUBSCRIPTION_ID" ]; then
    die "Azure returned an empty subscription ID."
fi

if ! SUBSCRIPTION_NAME=$(
    az account show \
        --query name \
        -o tsv \
        2>/dev/null
); then
    die "Unable to read Azure subscription."
fi

if [ -z "$SUBSCRIPTION_NAME" ]; then
    die "Azure returned an empty subscription name."
fi

echo
echo "Subscription:"
echo "  Name: $SUBSCRIPTION_NAME"
echo "  ID:   $SUBSCRIPTION_ID"
echo
echo "VM:"
echo "  Name: $VM_NAME"
echo "  User: $USERNAME"
echo "  Disk: StandardSSD_LRS"

# ------------------------------------------------------------
# Discover region policy
# ------------------------------------------------------------

echo

info "Checking subscription region policy..."

POLICY_STATUS=0

REGIONS=$(
    az policy assignment list \
        --scope "/subscriptions/$SUBSCRIPTION_ID" \
        --disable-scope-strict-match true \
        --query "[?displayName=='Allowed resource deployment regions'].parameters.listOfAllowedLocations.value[]" \
        -o tsv \
        2>/dev/null
) || POLICY_STATUS=$?

if [ "$POLICY_STATUS" -ne 0 ]; then
    die "Unable to read Azure Policy assignments for this subscription."
fi

# ------------------------------------------------------------
# Fallback when no explicit regional policy exists
# ------------------------------------------------------------

if [ -z "$REGIONS" ]; then

    warn "No explicit 'Allowed resource deployment regions' policy was found."

    info "Checking standard Azure locations..."

    PREFERRED_REGIONS=(
        westeurope
        northeurope
        swedencentral
        denmarkeast
        francecentral
        germanywestcentral
        polandcentral
        norwayeast
        switzerlandnorth
        italynorth
    )

    if ! AVAILABLE_REGIONS=$(
        az account list-locations \
            --query "[].name" \
            -o tsv \
            2>/dev/null
    ); then
        die "Unable to retrieve Azure regions."
    fi

    REGIONS=""

    for REGION in "${PREFERRED_REGIONS[@]}"; do
        if printf '%s\n' "$AVAILABLE_REGIONS" | grep -Fxq "$REGION"; then
            REGIONS+="$REGION"$'\n'
        fi
    done
fi

[ -n "$REGIONS" ] \
    || die "No Azure regions could be determined."

echo
echo "Regions to test:"
printf '%s\n' "$REGIONS"

# ------------------------------------------------------------
# Candidate VM sizes
# ------------------------------------------------------------
#
# These are intentionally small.
#
# Azure may still reject a size because of:
#   - quota
#   - regional capacity
#   - temporary capacity restrictions
#   - SKU availability
#
# The script handles those conditions automatically.
# ------------------------------------------------------------

SIZES=(
    Standard_B2as_v2
    Standard_B2ats_v2
    Standard_B2als_v2
    Standard_B2s_v2
    Standard_B1s

    Standard_D2as_v5
    Standard_D2s_v5
    Standard_D2as_v4
    Standard_D2a_v4
    Standard_D2s_v4

    Standard_DS1_v2
    Standard_D2_v5
)

# ------------------------------------------------------------
# Resource naming
# ------------------------------------------------------------
#
# Every resource group created by this script is tagged.
# This means previous runs can be cleaned without blindly
# deleting unrelated resource groups.
# ------------------------------------------------------------

MANAGED_BY_TAG="AzureVMBootstrap"
VM_TAG="$VM_NAME"

RG_PREFIX="azvm-${VM_NAME}"

# ------------------------------------------------------------
# Cleanup previous script-owned resource groups
# ------------------------------------------------------------

echo

info "Looking for previous deployments created by this script..."

OLD_RGS=$(
    az group list \
        --tag "ManagedBy=$MANAGED_BY_TAG" \
        --query "[?tags.VMName=='$VM_TAG'].name" \
        -o tsv \
        2>/dev/null || true
)

if [ -n "$OLD_RGS" ]; then

    while IFS= read -r OLD_RG; do

        [ -n "$OLD_RG" ] || continue

        warn "Deleting previous managed resource group: $OLD_RG"

        az group delete \
            --name "$OLD_RG" \
            --yes \
            --no-wait \
            --only-show-errors \
            >/dev/null 2>&1 || true

    done <<< "$OLD_RGS"

    info "Previous cleanup submitted."
else
    info "No previous managed deployment found."
fi

# ------------------------------------------------------------
# Deployment variables
# ------------------------------------------------------------

ATTEMPT=0

SUCCESS=0
SUCCESS_RG=""
SUCCESS_REGION=""
SUCCESS_SIZE=""
SUCCESS_IP=""

# ------------------------------------------------------------
# Region + SKU testing
# ------------------------------------------------------------

while IFS= read -r REGION; do

    [ -n "$REGION" ] || continue

    if [ "$SUCCESS" -eq 1 ]; then
        break
    fi

    for SIZE in "${SIZES[@]}"; do

        if [ "$SUCCESS" -eq 1 ]; then
            break
        fi

        ATTEMPT=$((ATTEMPT + 1))

        # Unique resource group per attempt.
        #
        # This prevents a failed deployment from poisoning
        # the next attempt with leftover NIC/VNet/NSG resources.
        ATTEMPT_RG="${RG_PREFIX}-a${ATTEMPT}-$(date +%s)"

        echo
        echo "============================================================"
        echo "Attempt: $ATTEMPT"
        echo "Region:  $REGION"
        echo "Size:    $SIZE"
        echo "RG:      $ATTEMPT_RG"
        echo "Disk:    StandardSSD_LRS"
        echo "============================================================"

        # ----------------------------------------------------
        # Resource group
        # ----------------------------------------------------

        info "Creating resource group..."

        RG_RESULT=$(
            az group create \
                --name "$ATTEMPT_RG" \
                --location "$REGION" \
                --tags \
                    ManagedBy="$MANAGED_BY_TAG" \
                    VMName="$VM_TAG" \
                --only-show-errors \
                -o none \
                2>&1
        )

        RG_STATUS=$?

        if [ "$RG_STATUS" -ne 0 ]; then

            warn "Resource group creation failed."

            printf '%s\n' "$RG_RESULT" | tail -10

            continue
        fi

        success "Resource group created."

        # ----------------------------------------------------
        # Preflight validation
        # ----------------------------------------------------
        #
        # --validate generates and validates the deployment
        # without creating the VM.
        #
        # StandardSSD_LRS is explicitly assigned to the OS disk.
        # ----------------------------------------------------

        info "Validating VM deployment..."

        VALIDATE_RESULT=$(
            az vm create \
                --resource-group "$ATTEMPT_RG" \
                --name "$VM_NAME" \
                --location "$REGION" \
                --size "$SIZE" \
                --image Ubuntu2404 \
                --storage-sku os=StandardSSD_LRS \
                --admin-username "$USERNAME" \
                --admin-password "$PASSWORD" \
                --authentication-type password \
                --nsg-rule SSH \
                --validate \
                --only-show-errors \
                -o none \
                2>&1
        )

        VALIDATE_STATUS=$?

        if [ "$VALIDATE_STATUS" -ne 0 ]; then

            if printf '%s\n' "$VALIDATE_RESULT" |
                grep -q "RequestDisallowedByAzure"; then

                warn "Blocked by Azure Policy."

            elif printf '%s\n' "$VALIDATE_RESULT" |
                grep -q "QuotaExceeded"; then

                warn "Quota does not allow $SIZE in $REGION."

            elif printf '%s\n' "$VALIDATE_RESULT" |
                grep -q "SkuNotAvailable"; then

                warn "SKU unavailable or restricted: $SIZE."

            else

                warn "Preflight validation failed."

                printf '%s\n' "$VALIDATE_RESULT" |
                    grep -E \
                        "Code:|Message:|code|message|AllocationFailed|QuotaExceeded|SkuNotAvailable|RequestDisallowedByAzure" |
                    head -15
            fi

            info "Submitting cleanup..."

            az group delete \
                --name "$ATTEMPT_RG" \
                --yes \
                --no-wait \
                --only-show-errors \
                >/dev/null 2>&1 || true

            continue
        fi

        success "Preflight validation succeeded."

        # ----------------------------------------------------
        # Actual VM creation
        # ----------------------------------------------------

        info "Creating VM..."

        CREATE_RESULT=$(
            az vm create \
                --resource-group "$ATTEMPT_RG" \
                --name "$VM_NAME" \
                --location "$REGION" \
                --size "$SIZE" \
                --image Ubuntu2404 \
                --storage-sku os=StandardSSD_LRS \
                --admin-username "$USERNAME" \
                --admin-password "$PASSWORD" \
                --authentication-type password \
                --nsg-rule SSH \
                --only-show-errors \
                -o json \
                2>&1
        )

        CREATE_STATUS=$?

        # ----------------------------------------------------
        # Success
        # ----------------------------------------------------

        if [ "$CREATE_STATUS" -eq 0 ]; then

            SUCCESS=1

            SUCCESS_RG="$ATTEMPT_RG"
            SUCCESS_REGION="$REGION"
            SUCCESS_SIZE="$SIZE"

            # Get the actual public IP from Azure instead of
            # parsing mixed stdout/stderr from az vm create.
            SUCCESS_IP=$(
                az vm show \
                    --resource-group "$SUCCESS_RG" \
                    --name "$VM_NAME" \
                    --show-details \
                    --query publicIps \
                    -o tsv \
                    2>/dev/null || true
            )

            if [ -z "$SUCCESS_IP" ]; then
                warn "VM was created, but its public IP could not be retrieved automatically."
            fi

            success "VM created successfully."

            # ------------------------------------------------
            # Expand SSH source to all IPv4 addresses.
            #
            # This intentionally exposes SSH on the Internet.
            # ------------------------------------------------

            NIC_ID=$(
                az vm show \
                    --resource-group "$SUCCESS_RG" \
                    --name "$VM_NAME" \
                    --query "networkProfile.networkInterfaces[0].id" \
                    -o tsv \
                    2>/dev/null || true
            )

            if [ -n "$NIC_ID" ]; then

                NSG_ID=$(
                    az network nic show \
                        --ids "$NIC_ID" \
                        --query "networkSecurityGroup.id" \
                        -o tsv \
                        2>/dev/null || true
                )

                if [ -n "$NSG_ID" ]; then

                    NSG_NAME="${NSG_ID##*/}"

                    az network nsg rule update \
                        --resource-group "$SUCCESS_RG" \
                        --nsg-name "$NSG_NAME" \
                        --name default-allow-ssh \
                        --source-address-prefixes 0.0.0.0/0 \
                        --only-show-errors \
                        -o none \
                        2>/dev/null || \
                        warn "SSH rule could not be widened automatically. Verify the NSG."
                fi
            fi

            break
        fi

        # ----------------------------------------------------
        # Failure classification
        # ----------------------------------------------------

        if printf '%s\n' "$CREATE_RESULT" |
            grep -q "AllocationFailed"; then

            warn "No current capacity for $SIZE in $REGION."

        elif printf '%s\n' "$CREATE_RESULT" |
            grep -q "QuotaExceeded"; then

            warn "Quota exceeded for $SIZE in $REGION."

        elif printf '%s\n' "$CREATE_RESULT" |
            grep -q "SkuNotAvailable"; then

            warn "SKU unavailable: $SIZE in $REGION."

        elif printf '%s\n' "$CREATE_RESULT" |
            grep -q "RequestDisallowedByAzure"; then

            warn "Azure Policy rejected $REGION."

        elif printf '%s\n' "$CREATE_RESULT" |
            grep -Eq \
                "AuthorizationFailed|AuthenticationFailed|ExpiredAuthenticationToken|Forbidden"; then

            printf '%s\n' "$CREATE_RESULT" | tail -15

            az group delete \
                --name "$ATTEMPT_RG" \
                --yes \
                --no-wait \
                --only-show-errors \
                >/dev/null 2>&1 || true

            die "Azure authorization or authentication failure."

        else

            warn "Unexpected VM creation error."

            printf '%s\n' "$CREATE_RESULT" |
                grep -E \
                    "Code:|Message:|code|message|AllocationFailed|QuotaExceeded|SkuNotAvailable|RequestDisallowedByAzure" |
                head -20

        fi

        # ----------------------------------------------------
        # Cleanup failed attempt
        # ----------------------------------------------------

        info "Submitting cleanup for failed attempt..."

        az group delete \
            --name "$ATTEMPT_RG" \
            --yes \
            --no-wait \
            --only-show-errors \
            >/dev/null 2>&1 || true

    done

done <<< "$REGIONS"

# ------------------------------------------------------------
# Final failure
# ------------------------------------------------------------

if [ "$SUCCESS" -ne 1 ]; then

    echo
    echo "============================================================"
    echo "DEPLOYMENT FAILED"
    echo "============================================================"
    echo
    echo "No tested region/SKU combination could create the VM."
    echo
    echo "Regions:"
    printf '%s\n' "$REGIONS"
    echo
    echo "VM sizes:"
    printf '%s\n' "${SIZES[@]}"

    exit 1
fi

# ------------------------------------------------------------
# Final verification
# ------------------------------------------------------------

unset PASSWORD PASSWORD_CONFIRM

echo
echo "============================================================"
echo "VM CREATED SUCCESSFULLY"
echo "============================================================"

az vm show \
    --resource-group "$SUCCESS_RG" \
    --name "$VM_NAME" \
    --show-details \
    --query "{
        Name:name,
        State:powerState,
        Location:location,
        Size:hardwareProfile.vmSize,
        PublicIP:publicIps,
        PrivateIP:privateIps,
        ResourceGroup:resourceGroup
    }" \
    -o table

echo
echo "Resource group:"
echo "$SUCCESS_RG"
echo
echo "SSH:"
if [ -n "$SUCCESS_IP" ]; then
    echo "ssh $USERNAME@$SUCCESS_IP"
else
    echo "Public IP unavailable. Retrieve it with:"
    echo "az vm show -g \"$SUCCESS_RG\" -n \"$VM_NAME\" --show-details --query publicIps -o tsv"
fi

echo
echo "Resources:"
az resource list \
    --resource-group "$SUCCESS_RG" \
    --query "[].{Name:name,Type:type,Location:location}" \
    -o table

echo
success "Deployment complete."
