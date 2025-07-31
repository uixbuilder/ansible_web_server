#!/bin/bash

# ==============================================================================
#
#  Ansible Secrets Step-by-Step Setup Script
#
#  This script interactively configures all necessary credentials for the
#  Ansible DigitalOcean playbook, storing them securely in Ansible Vault.
#
#  It manages:
#    1. Ansible Vault password file and ansible.cfg integration.
#    2. DigitalOcean API Token (in vault and digitalocean.yml).
#    3. SSH Key Pair (in vault).
#
# ==============================================================================

set -euo pipefail

# --- Configuration: File and Key Names ---
readonly INVENTORY_VAULT_FILE="inventory/group_vars/all/vault.yml"
readonly DO_INVENTORY_FILE="inventory/digitalocean.yml"
readonly ANSIBLE_CFG="ansible.cfg"
readonly VAULT_PASS_FILE=".vault_pass.txt"

readonly VAULT_DO_TOKEN_KEY="do_api_token"
readonly DO_INVENTORY_TOKEN_KEY="oauth_token"
readonly VAULT_SSH_PRIVATE_KEY="ssh_private_key"
readonly VAULT_SSH_PUBLIC_KEY="ssh_public_key"

readonly PLACEHOLDER_TOKEN="Place DigitalOcean token here"
readonly PLACEHOLDER_SSH_PRIVATE="Place SSH private key here"
readonly PLACEHOLDER_SSH_PUBLIC="Place SSH public key here"

# --- Debugging ---
DEBUG=${DEBUG:-false}

function debug() {
    if [[ "$DEBUG" == "true" ]]; then
        echo "DEBUG: $*" >&2
    fi
}

# --- Temporary File Cleanup ---
TMP_FILES=()
function cleanup_tmp {
    for f in "${TMP_FILES[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
}
trap cleanup_tmp EXIT

# --- Helper Functions ---
function step() { echo; echo "--- $1 ---"; }
function fail() { echo "❌ Error: $1" >&2; exit 1; }
function success() { echo "✅ $1"; }

# Retrieves a value from a YAML file, decrypting if necessary.
function get_yaml_var() {
    debug "Entering get_yaml_var with file='$1', key='$2'"
    local file="$1"
    local key="$2"
    [[ ! -s "$file" ]] && { debug "File '$file' is empty or does not exist"; return 1; }

    # Extract the line with the key
    local line
    line=$(grep -E "^${key}:" "$file" || true)
    debug "GREP output for key '$key': $line"
    [[ -z "$line" ]] && { debug "Key '$key' not found in '$file'"; return 1; }

    debug "Found line for key '$key': ${line:0:40}..."

    # Check if value is encrypted (starts with !vault)
    if echo "$line" | grep -q '!vault'; then
        debug "Value for key '$key' appears to be encrypted"
        # Extract only the vault blob (remove YAML key/tag/indentation)
        local vault_blob
        vault_blob=$(awk -v key="${key}:" '
            $1 == key {found=1; next}
            found && ($1 ~ /^[a-zA-Z0-9_]+:/) {exit}
            found && NF {sub(/^[[:space:]]+/, ""); print}
        ' "$file")
        debug "Extracted vault blob for key '$key' (first 80 chars): ${vault_blob:0:80}..."
        local decrypted
        decrypted=$(echo -e "$vault_blob" | ansible-vault decrypt --vault-password-file "$VAULT_PASS_FILE" --output - 2>/dev/null)
        debug "Decryption complete for key '$key', returning value starting with: ${decrypted:0:4}..."
        debug "Exiting get_yaml_var"
        printf "%s" "$decrypted"
    else
        local plain_value
        plain_value=$(echo "$line" | sed -E "s/^${key}:[[:space:]]*//")
        debug "Value for key '$key' is plain: ${plain_value:0:10}..."
        debug "Exiting get_yaml_var"
        printf "%s" "$plain_value"
    fi
}

# Encrypts a value with ansible-vault for a given key, outputs the encrypted block.
function encrypt_value() {
    debug "Entering encrypt_value for key='$2' with value starting with: ${1:0:4}..."
    local value="$1"
    local key="$2"
    local encrypted
    encrypted=$(ansible-vault encrypt_string --encrypt-vault-id default --vault-password-file "$VAULT_PASS_FILE" "$value")
    debug "Encryption complete for key='$key', encrypted content starts with: ${encrypted:0:10}..."
    debug "Exiting encrypt_value"
    printf "%s" "$encrypted"
}

# Updates a key in a YAML file with a given value (encrypted or plain).
function update_yaml_var() {
    local file="$1"
    local key="$2"
    local value="$3"
    touch "$file"
    local temp_file
    temp_file=$(mktemp)
    TMP_FILES+=("$temp_file")

    # Remove existing key block (including vault block if encrypted)
    awk -v key="$key" '
        BEGIN {skip=0}
        $0 ~ "^"key":" {skip=1; next}
        skip && /^[[:space:]]/ {next}
        {skip=0; print}
    ' "$file" > "$temp_file"

    # Append the new key value
    if [[ "$value" == \$ANSIBLE_VAULT* ]]; then
        # encrypted value, multiline
        echo "${key}: !vault |" >> "$temp_file"
        echo "$value" | sed 's/^/  /' >> "$temp_file"
    else
        # plain value, single line
        echo "${key}: $value" >> "$temp_file"
    fi

    mv "$temp_file" "$file"
}

# --- Prerequisite Check ---
function check_requirements() {
    debug "Checking required commands"
    for cmd in ansible-vault ssh-keygen curl awk grep sed; do
        command -v "$cmd" >/dev/null 2>&1 || fail "$cmd is required but not installed. Please install it to continue."
        debug "Command '$cmd' found"
    done
    # Ensure inventory directories exist
    mkdir -p "$(dirname "$INVENTORY_VAULT_FILE")"
    mkdir -p "$(dirname "$DO_INVENTORY_FILE")"
    touch "$ANSIBLE_CFG"
    debug "Prerequisite check complete"
}

# ==============================================================================
#  STEP 1: VAULT PASSWORD
# ==============================================================================
function setup_vault_password_file() {
    step "STEP 1: Ansible Vault Password"
    if [[ ! -f "$VAULT_PASS_FILE" ]]; then
        echo "Vault password file ($VAULT_PASS_FILE) not found."
        echo "Let's create one."
        while true; do
            read -sp "Enter a new password for Ansible Vault: " vault_pass
            echo
            read -sp "Re-enter the password to confirm: " vault_pass2
            echo
            if [[ "$vault_pass" == "$vault_pass2" ]] && [[ -n "$vault_pass" ]]; then
                debug "Vault password confirmed (not displayed for security)"
                break
            fi
            echo "Passwords did not match or were empty. Please try again."
        done
        printf "%s" "$vault_pass" > "$VAULT_PASS_FILE"
        chmod 600 "$VAULT_PASS_FILE"
        success "Vault password saved to $VAULT_PASS_FILE"
    else
        success "Vault password file ($VAULT_PASS_FILE) already exists."
    fi

    # Ensure ansible.cfg has the vault_password_file reference
    while ! grep -q "vault_password_file" "$ANSIBLE_CFG" 2>/dev/null; do
        echo "ℹ️  Please update your ansible.cfg ([defaults] section) to contain:"
        echo "vault_password_file = $VAULT_PASS_FILE"
        echo "Press Enter once you've updated the file to continue, or Ctrl+C to abort."
        read
    done
    success "Vault password file is referenced in $ANSIBLE_CFG."
}

# ==============================================================================
#  STEP 2: DIGITALOCEAN API TOKEN
# ==============================================================================
function manage_do_token() {
    step "STEP 2: DigitalOcean API Token"
    local current_token
    current_token=$(get_yaml_var "$INVENTORY_VAULT_FILE" "$VAULT_DO_TOKEN_KEY" || echo "")
    debug "Current DigitalOcean token in vault (redacted): ${current_token:0:4}..."

    if [[ -n "$current_token" && "$current_token" != "$PLACEHOLDER_TOKEN" ]]; then
        echo "An existing DigitalOcean API token was found in the vault."
        PS3="Your choice: "
        select opt in "Update token" "Remove token" "Skip"; do
            case $opt in
                "Update token")
                    prompt_and_update_do_token
                    break;;
                "Remove token")
                    remove_do_token
                    break;;
                "Skip")
                    echo "Skipping DigitalOcean token management."
                    break;;
            esac
        done
    else
        echo "No DigitalOcean API token found in the vault."
        prompt_and_update_do_token
    fi
}

function prompt_and_update_do_token() {
    local do_token
    while true; do
        read -p "Enter your DigitalOcean API token: " do_token
        [[ -n "$do_token" ]] || { echo "Token cannot be empty."; continue; }
        debug "User entered DigitalOcean token starting with: ${do_token:0:4}..."
        echo "Validating token with DigitalOcean API..."
        debug "Making API request to validate token"
        # Validate token by attempting to fetch account info
        if curl -s -f -X GET -H "Content-Type: application/json" -H "Authorization: Bearer $do_token" "https://api.digitalocean.com/v2/account" > /dev/null; then
            echo "Token is valid."
            debug "DigitalOcean token validated successfully"
            break
        else
            echo "Invalid token or network issue. Please check your token and try again."
            debug "DigitalOcean token validation failed"
        fi
    done
    
    local encrypted_token
    encrypted_token=$(encrypt_value "$do_token" "$VAULT_DO_TOKEN_KEY")
    debug "Updating vault file with encrypted DigitalOcean token:" "$do_token"
    update_yaml_var "$INVENTORY_VAULT_FILE" "$VAULT_DO_TOKEN_KEY" "$encrypted_token"
    debug "Updating DigitalOcean inventory file with encrypted DigitalOcean token"
    update_yaml_var "$DO_INVENTORY_FILE" "$DO_INVENTORY_TOKEN_KEY" "$encrypted_token"
    success "DigitalOcean token has been securely stored."
}

function remove_do_token() {
    debug "Removing DigitalOcean token from vault and inventory files"
    update_yaml_var "$INVENTORY_VAULT_FILE" "$VAULT_DO_TOKEN_KEY" "$PLACEHOLDER_TOKEN"
    update_yaml_var "$DO_INVENTORY_FILE" "$DO_INVENTORY_TOKEN_KEY" "$PLACEHOLDER_TOKEN"
    success "DigitalOcean token has been removed and replaced with a placeholder."
}


# ==============================================================================
#  STEP 3: SSH KEY PAIR
# ==============================================================================
function manage_ssh_keys() {
    step "STEP 3: SSH Key Pair"
    local current_key
    current_key=$(get_yaml_var "$INVENTORY_VAULT_FILE" "$VAULT_SSH_PRIVATE_KEY" || echo "")
    debug "Current SSH private key in vault (redacted): ${current_key:0:4}..."

    if [[ -n "$current_key" && "$current_key" != "$PLACEHOLDER_SSH_PRIVATE" ]]; then
        echo "An existing SSH key was found in the vault."
        PS3="Your choice: "
        select opt in "Add/Update key" "Remove key" "Skip"; do
            case $opt in
                "Add/Update key")
                    prompt_and_update_ssh_keys
                    break;;
                "Remove key")
                    remove_ssh_keys
                    break;;
                "Skip")
                    echo "Skipping SSH key management."
                    break;;
            esac
        done
    else
        echo "No SSH key found in the vault."
        prompt_and_update_ssh_keys
    fi
}

function prompt_and_update_ssh_keys() {
    PS3="How would you like to provide the SSH key? "
    select opt in "Provide path to existing key files" "Generate a new key pair" "Cancel"; do
        case $opt in
            "Provide path to existing key files")
                add_existing_ssh_key_pair
                break;;
            "Generate a new key pair")
                generate_new_ssh_key_pair
                break;;
            "Cancel")
                echo "SSH key setup cancelled."
                debug "User cancelled SSH key setup"
                break;;
        esac
    done
}

function add_existing_ssh_key_pair() {
    local priv_key_path pub_key_path
    read -e -p "Enter the full path to your PRIVATE SSH key file (e.g., ~/.ssh/id_ed25519): " priv_key_path
    read -e -p "Enter the full path to your PUBLIC SSH key file (e.g., ~/.ssh/id_ed25519.pub): " pub_key_path
    debug "User provided private key path: $priv_key_path"
    debug "User provided public key path: $pub_key_path"
    if [[ ! -f "$priv_key_path" ]] || [[ ! -f "$pub_key_path" ]]; then
        fail "One or both key files not found. Please check the paths."
    fi
    local priv_key_content pub_key_content
    priv_key_content=$(cat "$priv_key_path")
    pub_key_content=$(cat "$pub_key_path")
    debug "Read private key content starting with: ${priv_key_content:0:4}..."
    debug "Read public key content starting with: ${pub_key_content:0:4}..."
    encrypt_and_update_ssh_keys "$priv_key_content" "$pub_key_content"
    success "SSH key pair from files has been securely stored in the vault."
}

function generate_new_ssh_key_pair() {
    local key_path="$HOME/.ssh/ansible_do_key"
    echo "A new ED25519 key pair will be generated."
    read -p "Enter file path to save new key (default: $key_path): " custom_path
    key_path="${custom_path:-$key_path}"
    debug "Generating new SSH key pair at path: $key_path"
    if [[ -f "$key_path" ]]; then
        read -p "⚠️  File '$key_path' already exists. Overwrite? (y/N): " confirm_overwrite
        if [[ "${confirm_overwrite}" != "y" ]]; then
            echo "Generation cancelled."
            debug "User cancelled SSH key generation due to existing file"
            return
        fi
    fi
    ssh-keygen -t ed25519 -f "$key_path" -N "" -q
    local priv_key_content pub_key_content
    priv_key_content=$(cat "$key_path")
    pub_key_content=$(cat "${key_path}.pub")
    debug "Generated private key content starting with: ${priv_key_content:0:4}..."
    debug "Generated public key content starting with: ${pub_key_content:0:4}..."
    encrypt_and_update_ssh_keys "$priv_key_content" "$pub_key_content"
    success "New SSH key pair generated and securely stored in the vault."
    echo "🔑 Private key: $key_path"
    echo "🔑 Public key:  ${key_path}.pub"
}

function encrypt_and_update_ssh_keys() {
    local priv_key_content="$1"
    local pub_key_content="$2"
    local encrypted_priv_key encrypted_pub_key
    encrypted_priv_key=$(encrypt_value "$priv_key_content" "$VAULT_SSH_PRIVATE_KEY")
    encrypted_pub_key=$(encrypt_value "$pub_key_content" "$VAULT_SSH_PUBLIC_KEY")
    debug "Updating vault file with encrypted SSH private key"
    update_yaml_var "$INVENTORY_VAULT_FILE" "$VAULT_SSH_PRIVATE_KEY" "$encrypted_priv_key"
    debug "Updating vault file with encrypted SSH public key"
    update_yaml_var "$INVENTORY_VAULT_FILE" "$VAULT_SSH_PUBLIC_KEY" "$encrypted_pub_key"
}

function remove_ssh_keys() {
    debug "Removing SSH keys from vault file"
    update_yaml_var "$INVENTORY_VAULT_FILE" "$VAULT_SSH_PRIVATE_KEY" "$PLACEHOLDER_SSH_PRIVATE"
    update_yaml_var "$INVENTORY_VAULT_FILE" "$VAULT_SSH_PUBLIC_KEY" "$PLACEHOLDER_SSH_PUBLIC"
    success "SSH keys have been removed and replaced with placeholders."
}


# ==============================================================================
#  MAIN EXECUTION
# ==============================================================================
main() {
    debug "Starting main execution"
    echo "==============================================="
    echo "  Ansible Project Secrets Setup Utility"
    echo "==============================================="

    check_requirements
    setup_vault_password_file
    manage_do_token
    manage_ssh_keys

    echo
    echo "🎉 Setup complete! You can run this script again anytime to manage your secrets."
    debug "Main execution complete"
}

main "$@"
