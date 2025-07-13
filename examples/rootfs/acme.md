acme.rootfs
===========

This is a full example for a virtual machine that can be used to keep X.509
certificates of multiple systems up-to-date. It handles requesting or renewing
private keys and certificates, solving DNS challenges, deploying keys and
certificates and updating TLSA records.
Certificates are stored persistently, but private keys are not. They are kept
solely in memory.

When the machine starts, it performs the following steps:
 1. Check for certificates that are missing or about to expire soon
 2. Generate a new key pair for these certificates
 3. Generate a new CSR for these certificates
 4. Requests new certificates using the ACME protocol
 5. Prove domain ownership using the DNS challenge method
 6. Update TLSA records (if any) to the new certificates, wait for the cached
    TLSA records to expire
 7. Deploy the new keys and certificates to the systems that need them
 8. Wait until the target systems use the new certificates
 9. Remove the TLSA records of the previous certificates (if any)
10. The machine shuts down

Configuration
=============

A number of additional files are required to complete the example. These files
need be added to the `acme` directory.

main.conf
---------
This is the global configuration file. It stores simple key value pairs, each
on it's own line and separated by a colon and (at least) one whitespace
character (e.g. `key: value`). Lines that are formatted incorrectly or contain
unknown configuration options are silently ignored. Comments can therefore be
added on their own line in any style.

The following configuration options are supported:
* `account_email`  
  The e-mail address with which to register at the ACME CA. Required.
* `acme_url`  
  The URL to the CA's ACME API. This can be used to switch to a staging
  environment for testing purposes, for example.
* `dns_provider`  
  The name of one of Lego's built-in DNS providers to make Lego handle DNS
  challenges. If this is set, TLSA records can not be managed (see [DNS
  Management](#dns-management) below).
* `min_validity`  
  Minimum certificate validity in days. If a stored certificate will expire
  within this time, a new certificate is requested. Default value is `30`.
* `profile`  
  Name of the certificate profile to request.
  Refer to the CA's documentation for a list of valid profile names.
  When not set, the profile is selected by the CA.
* `key_type`  
  Type and length of the key pair to generate for the certificate. Consists of
  the algorithm (`rsa` or `ec`) followed by the key length. Default value is
  `ec256`.
* `deploy`  
  Deployment method (see [Deployment](#deployment) below). Default value if
  `sftp`.
* `verify`  
  Deployment Verification method (see [Verification](#verification) below).
  Default value is `connect`.
* `verify_timeout`  
  Deployment verification timeout in seconds. Default value is `300`.
* `lego_args`  
  Additional command line arguments to pass to `lego run` or `lego renew`.
  Refer to [Lego's documentation](https://go-acme.github.io/lego/usage/cli/)
  for more information. Note that some options offered by Lego may conflict
  with other options enforced by this system. Use with care.

main.env
--------
This file allows for additional environment variable definition.
This may be required when using Lego's internal DNS provider support.
Each environment variable needs to be defined on it's own line and separated by
it's value by a single `=` (and no spaces).
Lines that are formatted incorrectly are silently ignored. Comments can
therefore be added on the line in any style.

$domain.conf
------------
A domain-specific configuration file is *required* for each domain that should
be managed by the system. The domain for which to request a certificate is
inferred from the file name. The configuration file may be empty. It may also
contain the same configuration options (and uses the same file format) as
`main.conf`. In addition, the following domain-specific option can be set:
* `alt_domains`  
  Additional domains or host names (separated by spaces) to include in the
  certificate's Subject Alternative Name (SAN) extension.

$domain.env
-----------
This file allows defining domain-specific environment variables, similar to
what can be done with `main.env` globally.

DNS Management
--------------
[Lego](https://go-acme.github.io/lego/) is used interface with an ACME
compatible CA (such as [Let's Encrypt](https://letsencrypt.org/)).
Lego supports a number of DNS providers to solve the DNS challenge.
However, it does not handle TLSA records.

For this purpose, the script `update-dns.sh` was added. Currently, it only
supports [deSEC](https://desec.io/) as a DNS provider (using
[desec-dns](https://github.com/s-hamann/desec-dns)). To use another DNS
provider *and* handle TLSA records correctly, `update-dns.sh` needs to be
changed accordingly. If the target system does not have TLSA records, Lego's
internal DNS handling can be used (see `main.conf` and `main.env`).

desec_token
-----------
The file `desec_token` needs to contain an authentication token for the
[deSEC](https://desec.io/) API. This is only used with the default
`update-dns.sh` implementation.

Deployment
----------
The system supports pluggable deployment methods.
Currently, the only implemented deployment method is `sftp`, which uploads
private keys and certificates to the target systems using SFTP.
The files are simply dropped in the directory `upload` in the home directory of
the connecting user and the target system is responsible for moving them to the
correct location.

To implement another deployment method, add a file `deploy_$method.sh` to the
`acme` directory.
The file must be an executable (script or binary) that handles deployment.
When called, it receives three parameters:
* `domain`  
  The domain name the certificate is issued for, i.e. usually the host name of
  the target system.
* `cert_dir`  
  The directory where the newly issues certificate (`$domain.unbundled.crt`) is
  stored. This directory also contains the issuer certificate
  (`$domain.issuer.crt`) and a bundled version (`$domain.crt`).
* `key_path`  
  The path to the private key file for the certificate.

The program should return the exit code `0` if the deployment worked correctly
and any other exit code if there was an error.

Verification
------------
When managing TLSA records, the system verifies that the new key and
certificate are successfully deployed to the target system before removing TLSA
records that reference the old key and certificate. For this purpose, pluggable
methods are supported, similar to the deployment methods.
Currently, two methods are supported:
* `connect`  
  Connects to each port referenced by a TLSA record and checks that the service
  presents the new certificate.
* `timeout`  
  Simply waits for a configurable time to pass. Does not actually verify anything.

To implement another verification method, add a file `verify_$method.sh` to the
`acme` directory.
The file must be an executable (script or binary) that handles deployment
verification. When called, it receives three parameters:
* `cert_path`  
  The path to the new certificate.
* `timeout`  
  The user-configured timeout (in seconds) after which the verification should
  terminate.
* `tlsa-records`  
  The original TLSA records. Records are in zone file format, separated by `;`.

The program should run until either the deployment is complete or the timeout
is reached. It should return the exit code `0` if the deployment is successful
and any other exit code if the deployment could not be verified within the time
limit.

SSH setup
---------
The SSH client needs to be configured correctly in order to deploy keys and
certificates via SFTP. This usually includes the following three components:
1. One (or more) SSH private key(s) (`id_ed25519` or similar) that can log in
   to the target systems.
2. A `known_hosts` file that contains the SSH server public keys of all target
   systems. Of course, a SSH CA can be used to avoid tedious key management.
3. A SSH client configuration (`ssh_config`). This file can be used to
   configure which user name is used to login to the target systems and all
   other options supported by OpenSSH (see `man 5 ssh_config`).

Persistent Storage
------------------
As this system stores file (ACME account and certificates) persistently, a
second disk is required. It needs to have the file system label `data`.
Such a disk can be created using the following commands (or something similar):

```sh
dd if=/dev/zero of=acme-data.img bs=1M count=32 # create a 32 MiB disk image
mkfs.ext2 -L data -m 0 acme-data.img # format the disk image with an ext2 file system
chmod 600 acme-data.img # restrict read access from unauthorized users
```

The MicroVM configuration needs to reference this image as a secondary disk, e.g.
```json
{
  "drives": [
    {
      "drive_id": "rootfs",
      "path_on_host": "acme.img",
      "is_root_device": true,
      "is_read_only": true
    },
    {
      "drive_id": "data",
      "path_on_host": "acme-data.img",
      "is_root_device": false,
      "is_read_only": false
    }
  ]
}
```
