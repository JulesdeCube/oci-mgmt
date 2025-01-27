# OCI Manager

Simple script to manage OCI image inside a tarball.

## Build

To build the script use:

```nix
nix build
```

result under `result/bin/oci-mgmt`

## Run

To run the program.

```sh
nix run .# --
```

or

```sh
nix run git+https://gitlab.julesdecube.com/julesdecube/oci-mgmt.git
```

or

```sh
nix run github:julesdecube/oci-mgmt
```
