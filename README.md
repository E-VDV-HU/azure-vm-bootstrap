# Azure VM Bootstrapper

AI-generated with ChatGPT (GPT-5.6 Luna).

A Bash-based Azure VM provisioning script designed for Azure CLI and Azure Cloud Shell. It interactively asks for the VM name, Linux username, and password, then handles region restrictions, VM SKU availability, quota errors, deployment validation, networking, and cleanup.

## TL;DR
Quick install on cloudshell:
```bash
git clone https://github.com/E-VDV-HU/azure-vm-bootstrap.git
cd azure-vm-bootstrap
chmod +x create-vm.sh
./create-vm.sh
```

or no install run(easier):
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/E-VDV-HU/azure-vm-bootstrap/main/create-vm.sh)
```

## Features

The script:

* Uses the currently selected Azure subscription.
* Reads the subscription's `Allowed resource deployment regions` policy when present.
* Avoids blindly creating resources in unsupported regions.
* Prompts for:

  * VM name
  * Linux username
  * Password
* Validates the Linux username and password locally.
* Uses Ubuntu 24.04.
* Tries multiple small VM sizes.
* Performs Azure preflight validation before the real deployment.
* Handles quota, SKU, policy, and regional capacity failures.
* Creates the resource group, VNet, subnet, NSG, NIC, and public IP automatically through Azure CLI.
* Opens SSH access.
* Cleans failed deployment resource groups asynchronously.
* Removes resource groups previously created by the script for the same VM name.
* Prints the final VM connection information.

## Requirements

You need:

* An Azure subscription
* Azure CLI
* An authenticated Azure CLI session
* Bash
* Python 3

Azure Cloud Shell already provides the required environment.

Check Azure CLI authentication with:

```bash
az account show
```

## Usage

Make the script executable:

```bash
chmod +x create-vm.sh
```

Run it:

```bash
./create-vm.sh
```

The script will ask:

```text
VM name:
Username:
Password:
Confirm password:
```

It uses the subscription currently selected in Azure CLI.

To change subscriptions before running:

```bash
az account set --subscription YOUR_SUBSCRIPTION_ID
```

Then verify:

```bash
az account show
```

## Deployment behavior

The script does not assume that a particular Azure region is usable.

Some Azure subscriptions, especially restricted/student subscriptions, may have an Azure Policy limiting VM deployment to a small set of regions. The script reads that policy when available and only attempts those locations.

Azure CLI exposes applicable policy assignments with `az policy assignment list`.

The script also does not assume that a VM size being listed in a region means that the VM can actually be allocated there. Azure can reject a deployment because of quota or temporary regional capacity.

The script therefore uses this sequence:

```text
subscription
    |
    v
allowed regions
    |
    v
candidate VM size
    |
    v
resource group
    |
    v
preflight validation
    |
    v
actual VM deployment
    |
    +---- failure ----> asynchronous cleanup
    |
    v
success
```

## Resource cleanup

Each deployment attempt receives its own temporary resource group.

This is intentional.

A failed VM deployment can leave networking resources behind. Reusing the same resource group after a failed attempt can therefore produce confusing `ResourceNotFound`, name collision, or deployment-state errors.

Failed attempt groups are deleted with `--no-wait`, preventing the script from blocking while Azure performs a potentially long resource-group deletion.

Only resource groups tagged by this script are automatically removed.

The script uses:

```text
ManagedBy=AzureVMBootstrap
VMName=<requested VM name>
```

This avoids deleting arbitrary resource groups in the subscription.

## SSH

The VM is created with password authentication.

The automatic SSH NSG rule is subsequently changed to:

```text
0.0.0.0/0
```

That permits SSH connections from any IPv4 address.

This is intentionally open to the Internet and should be changed to a restricted source IP or CIDR range for production systems.

## Security

Do not put passwords, tokens, subscription credentials, or SSH private keys into the repository.

The password is requested interactively and is not stored in the script.

The password is still passed to Azure CLI during VM creation, so the host environment running the script should be considered trusted.

## AI disclosure

This project is AI-generated.

Generated with:

```text
ChatGPT
Model: GPT-5.6 Luna
Date: 2026-09-24
```

The code should be reviewed and tested before production use.

## License

Choose an appropriate license before publishing the repository.
