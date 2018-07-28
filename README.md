# nanobox-unity
============================
A small collection of scripts to set up new on-premise installations of Nanobox

Scripts
-------
The scripts included here, and their individual purposes, are:

- `provider/bin/bootstrap`: set up the hosting provider to house all required
  components of the installation
- `controller/bootstrap`: script used to install Nanobox components
- `host/ubuntu.sh`: script used to provision and configure new app host servers
  from within Nanobox itself

You should note the commit ID of the version of these scripts that you actually
run, so that any audits of your infrastructure can be accurately performed.

Usage
-----
### `provider/bin/bootstrap` ###

This script should be run from a computer with Python and access to the target
provider. Available providers can be looked up by running
`provider/bin/bootstrap -h`.

The default configuration involves creating two self-contained environments,
`production` and `staging`. The `production` environment is further segmented
into zones (see below) for increased security and compliance with various
security and auditing regulations, while `staging` is set up without the extra
compilance requirements and access restrictions that come with using said zones.
In any configuration, each environment is set up with a dedicated access control
role, to prevent access to either without explicit authorization.

The default configuration also creates four provider-level zones (generally
implemented as subnets, but potentially involving other concepts or terms)
within environments configured to use them:

- **DMZ**: **D**e**m**ilitarized **Z**one, a zone which allows access from the
  outside world, so that it is still possible to access the various components
  of the Nanobox deployment, and any apps running within it.
- **MGZ**: **M**ana**g**ement **Z**one, used to host the Nanobox Controller, and
  any other components required to manage the intsallation.
- **APZ**: **Ap**plication **Z**one, where all the deployed apps will end up.
- **SDZ**: **S**ecure **D**ata **Z**one, used for secure but shared data
  storage, in the event RDS or another external service isn't used for that
  purpose.

In addition to the zones themselves is the overall security setup for each.

Other configurations are possible via the `nanobox.yml` configuration file,
detailed below (along with the defaults above as described within that file).

Once all of these are set up, we launch a server in each environment and set up
the Nanobox Controller on each. The specifics of how these controllers are set
up is the responsibility of the `controller/bootstrap` script, detailed below.

Finally, we ensure everything is properly configured, installed, and secured,
before locking down the entire infrastructure to only be accessible by
authorized personnel. To do this, we configure the infrastructure's external
logging service, add additional components required by the installer
configuration, and perform final integration and testing to ensure everything is
working as expected.

### `controller/bootstrap` ###

The primary responsibility of this script is to perform the initial setup of a
Nanobox controller, ensuring the associated software and services are properly
installed and configured for each environment. It will also ensure the required
user accounts are properly set up on the controller, so that the environment can
properly be managed.

### `host/ubuntu.sh` ###
_TODO_

An extended version of [the public Nanobox bootstrap
script](https://github.com/nanobox-io/bootstrap/blob/master/ubuntu.sh), with
adjustments for an on-premise configuration, such as installing/configuring a
File Integrity Monitor (FIM), and automatically shipping system logs to an
external location/service.

Configuration
-------------
The default configuration provides a good overview of the available options:

```yaml
environments:
  production:
    use_zones: true
    application_zone: apz
  staging:
    use_zones: false
zones:
  dmz:
    components:
      - vpn
      - gateway
      - waf
    networking:
      in:
        - pub
        - mgz
        - apz
      out:
        - pub
        - mgz
        - apz
  mgz:
    components:
      - controller
    networking:
      in:
        - dmz
        - apz
      out:
        - dmz
        - apz
        - sdz
  apz:
    networking:
      in:
        - dmz
        - mgz
      out:
        - dmz
        - mgz
        - sdz
  sdz:
    networking:
      in:
        - apz
        - mgz
```

<!-- EOF -->
