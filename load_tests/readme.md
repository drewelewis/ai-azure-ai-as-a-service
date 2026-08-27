# Azure Load Testing Plans

## Overview

This directory contains the JMeter-compatible test plans consumed by Azure Load
Testing. JMX is the workload format used by the managed service; these files do
not imply that a local JMeter engine is required or supported. Developers launch
and monitor Azure-hosted test runs from their local workstation with PowerShell.

All five tests are configured automatically for the `complete-development`
profile during `azd provision`. The production profile does not deploy Azure Load
Testing or configure test definitions.

| Definition | Target | Subscription coverage |
|---|---|---|
| `definitions/apim-load-test.jmx` | Internal APIM directly | Representative Bronze and Silver use cases |
| `definitions/appgw-load-test.jmx` | Application Gateway to APIM | Representative Bronze and Silver use cases |
| `definitions/failover-load-test.jmx` | Application Gateway to APIM circuit-state routing | Representative Silver use case |
| `definitions/multi-sub-failover-test.jmx` | Application Gateway to APIM under shared pressure | All eight LOB use cases across Bronze, Silver, and Gold |
| `definitions/steady-state-test.jmx` | Application Gateway to APIM for one hour | All eight LOB use cases across Bronze, Silver, and Gold |

## Configuration Ownership

- `infrastructure/bicep/load-testing.bicep` creates the Azure Load Testing
  resource, managed identity, and VNet Network Contributor assignment.
- `infrastructure/bicep/networking.bicep` creates the dedicated
  `snet-loadtest` subnet and permits HTTPS from that subnet to internal APIM.
- `infrastructure/bicep/main.bicep` exports `LOAD_TEST_SUBNET_ID`.
- `definitions/*.jmx` defines workload behavior and assertions.
- `scripts/configure-load-test.ps1` creates or updates each data-plane test,
  uploads artifacts, assigns the subnet, and verifies the assignment.
- `scripts/run_load_test.ps1` starts tests that are already configured, and
  `scripts/invoke_load_test.ps1` contains the shared Azure run/poll logic.

Azure Load Testing test definitions and uploaded JMX artifacts are data-plane
objects rather than Bicep resources. Bicep therefore owns the Azure workspace,
network, identity, and RBAC; the azd postprovision script reconciles the test
definitions.

## Private Network Path

Every test is assigned the Bicep-exported `LOAD_TEST_SUBNET_ID`. Azure Load
Testing injects its test-engine NICs into `snet-loadtest`, where they use the
VNet's private DNS links and routes.

The direct APIM smoke test resolves the internal APIM hostname from inside the
VNet. The other four plans target Application Gateway, which forwards to internal
APIM. APIM reaches both Foundry accounts over private endpoints and authenticates
with its managed identity.

Configuration fails closed when the subnet output is missing. After creating or
updating each test, `scripts/configure-load-test.ps1` reads the test's `subnetId`
from Azure and fails if it does not match `LOAD_TEST_SUBNET_ID`.

## Subscription Keys

The JMX files contain variable names, not credentials. During postprovision, the
signed-in provisioning identity retrieves the APIM subscription keys through the
Azure management API. The configuration script writes a temporary
`user.properties` file for each test, uploads it as a USER_PROPERTIES artifact,
and deletes the local temporary file.

Azure Load Testing receives APIM subscription keys only. Foundry keys are not
used or distributed; APIM authenticates to Foundry with managed identity.

## Running Tests

### Workstation prerequisites

- PowerShell 7 or later.
- Azure CLI authenticated to the target tenant and subscription.
- The Azure CLI `load` extension.
- Azure Developer CLI with the target environment selected.
- A completed `azd provision` for the `complete-development` profile.

From the repository root, launch the interactive Azure test runner locally:

```powershell
.\_loadtest.bat
```

The root batch file forwards arguments to `scripts/run_load_test.ps1`. On
non-Windows systems, invoke that PowerShell script directly.

The launcher starts one of the five definitions already reconciled by
`azd provision`. Before creating a run, it verifies that Application Gateway is
healthy and running. If the gateway is stopped, the launcher runs the repository's
`azd hooks run postprovision` lifecycle to start and validate it, then fails closed
unless Azure reports `provisioningState=Succeeded` and `operationalState=Running`.
The local process discovers the load-testing resource in the selected azd
subscription, then starts and polls the run through its data-plane endpoint using
a subscription-scoped token. This keeps polling stable if another process changes
the global Azure CLI account context. Three consecutive polling failures stop the
launcher with the underlying error instead of appearing as blank statuses until
timeout. The launcher propagates a failed result through its exit code. All traffic
generation occurs on VNet-injected Azure Load Testing engines. Automation can
select a test through the same launcher with `-TestId`.

For example, launch the direct private-APIM smoke test without the menu:

```powershell
.\_loadtest.bat -TestId apim-smoke-test
```

If test definitions or network settings change, run `azd provision` again before
starting a test. Do not create or modify test definitions manually in the Azure
portal because the next provision reconciles them from this repository.

## Files

| Path | Purpose |
|---|---|
| `definitions/*.jmx` | Five workload plans executed by Azure Load Testing |
| `config/system.properties` | JMeter system properties uploaded with applicable plans |
| `config/appgw-system.properties` | Application Gateway TLS properties uploaded with applicable plans |
| `config/appgw-truststore.p12` | Generated truststore for the Bicep-provisioned Application Gateway certificate |
| `config/appgw-cert.cer` | Exported Application Gateway public certificate |
| `scripts/run_load_test.ps1` | Interactive and parameterized launcher for all managed test definitions |
| `scripts/invoke_load_test.ps1` | Shared Azure test-run creation, polling, and result handling |

## Adding a Test

1. Add the JMX plan under `definitions/`.
2. Add a `Register-AltTest` entry to `scripts/configure-load-test.ps1`.
3. Add the test metadata and `ValidateSet` value to `scripts/run_load_test.ps1`.
4. Run `azd provision` to reconcile and validate the test definition.