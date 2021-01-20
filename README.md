# Ember-CSI & Operator e2e tests

The primary purpose of this repository is to provide an easy way to automate
running the OpenShift end-to-end CSI tests against an Ember-CSI plugin deployed
using the Ember-CSI operator using any of the supported storage systems.

This is accomplished with the ``start.sh`` script and accompanying files using
the [Code Ready Containers (CRC) system](https://code-ready.github.io/crc/) to
create a VM running a single node OpenShift cluster where the script deploys
the Ember-CSI OLM operator, then asks it to deploy the configured Ember-CSI
backend, and finally runs the OpenShift end-to-end CSI tests.

The script divides the whole process into phases, allowing us to decide up to
what phase we want it to run, in case there is something we want to run
manually.

## Features

These are the features currently supported by the ``start.sh`` script:

- Download and install CRC and its requirements
- Deploy OpenShift cluster and proxy its web console
- Deploy the Ember-CSI operator
  * From official container image
  * From a custom repository image
  * From source code
- Deploy Ember-CSI with a specific backend
  * From official container image
  * From a custom repository image
  * From source code
- Run end-to-end CSI tests
  * Using Ember-CSI container
  * Locally rebuilding the container if necessary
- Clean some process phases deployed on the VM

## Phases

These are the phases known by the script:

- Get CRC
- Setup CRC and its requirements
- Start the OpenShift cluster in a VM
- Run the Ember-CSI operator: Will push the container into the cluster's
  registry after building from source or pulling custom image when necessary.
- Ensure the Ember-CSI container is in the cluster's registry: Building or
  pulling it before pushing when necessary.
- Run the Ember-CSI plugin
- Run end-to-end tests

## Running it

If we don't change the configuration the script will run with the LVM backend
defined in ``lvmdriver.yaml`` file.

To create an OpenShift cluster in a VM, deploy the operator, Ember-CSI with
the LVM backend, and run the end-to-end tests we just need to run:

```bash
  ./start.sh e2e
```

For an explanation on how to use the Ember-CSI operator's form to manually
deploy a plugin look at the *Automation* section.

Additional examples can be found at the beginning of the ``start.sh`` script,
and help can be seen by running:

```bash
  ./start.sh help
```

## Artifacts

The cluster configuration as well as the logs from running the script are
stored in the ``test-artifacts`` directory or wherever the ``ARTIFACTS_DIR``
configuration option defines.

After a full run of the script we'll find the following files in the directory:

- Cluster configuration: ``kubeconfig.yaml``
- OpenShift CLI client: ``oc``
- Output from the script: ``execution.log``
- Output from the e2e test run: ``test-run.log``
- Output from kubelet: ``kubelet.log``
- Output from relevant containers: ``<pod>-<container>.log``
- IP address of the CRC node: ``crc-ip.txt``

## Configuration

The script gets its configuration from a file or environmental variables.
Full list of options with their description can be found in the
``sample_config`` file.

The script looks by default for a ``config`` file in the current directory to
source and get the configuration, but a different file can be provided through
the command line.

Among the different configuration options there's one that deserves special
attention, and that's the ``DRIVER_FILE`` option used to define the location of
the Ember-CSI plugin configuration.  This file is not necessary if we manually
deploy the plugin using the OpenShift web console.

## Automation

When we want to automate the end-to-end tests we need to have a manifest with
the right configuration, but we may not know what the configuration parameters
are the first time, so how do we go about it?

First we ask the script to setup CRC, deploy a VM with an OpenShift cluster,
and stop right after installing the Ember-CSI operator:

```bash
  ./start.sh container
```

Then we go to the OpenShift console web console to create a Backend:
  **Operators** > **Installed Operators** > **Ember CSI Operator** > **Create Instance**

That will bring us to a form where we'll be able to select our storage system
from a drop down, which will make the form display only relevant configuration
options for our backend.

> The name of the backup must always be **backend**.

For example for the LVM backend we would select:

- Name: ``backend``
- Driver: ``LVMVolume``
- Target Helper: ``lioadm``
- Volume Group: ``ember-volumes``
- Target Ip Address: *IP address found in the crc-ip.txt file in the artifacts
  directory*

Once we create that backend, the Ember-CSI operator will deploy the Ember-CSI
plugin to manager our storage system.

At this point we can test things manually ourselves using the manifests present
in ``maniftests/manual`` to create a PVC and then run a trivial pod that uses
it:

```bash
  test-artifacts/oc create -f manifests/manual/pvc.yaml
  test-artifacts/oc create -f manifests/manual/app.yaml

```

If everything goes as expected, we'll end up with a running ``my-csi-app`` pod.
At this point we know the Ember-CSI plugin is able to communicate with the
storage system and we can attach volumes, so we can destroy the pod and the PVC
if we want to.

Now that we know the configuration is valid we should save this configuration
so we can automate the configuration and deployment phases.

Given the sensitive nature of this information it is stored as a secret in the
OpenShift cluster, so we have 2 ways to get this information:

We can use the OpenShift's client to read the secret itself:

```bash
  oc get secret ember-csi-operator-backend -o jsonpath='{.data}'|python -c 'import json, sys, base64, pprint; data=sys.stdin.read(); pprint.pprint(json.loads(base64.decodestring(data.split(":")[1][:-1])));'
```

Or we can check the environmental variable used by the Ember-CSI plugin:

```bash
  oc exec -t backend-controller-0 -c ember-csi -- /bin/bash -c 'echo $X_CSI_BACKEND_CONFIG'
```

With this information we can now create our own ``EmberStorageBackend``
manifest and set its location on the ``DRIVER_FILE`` configuration option.

Now we can tell the script to run the end-to-end tests.  The script will
recognize the presence of the Ember-CSI plugin we manually deployed because we
used the ``backend`` name, so it will skip that step.

```bash
  ./start.sh e2e
```
