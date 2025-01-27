{
  # Description of the project
  description = "Simple script to manage oci tarball";

  # Input flakes to get depencices
  inputs = {
    # Main repository to sync flakes
    snowball.url = "git+https://gitlab.julesdecube.com/infra/snowball.git";
    # Main stable nixpkgs libraries
    nixpkgs.follows = "snowball/nixpkgs";
    # Simple library to generate system specific derivation
    flake-utils.follows = "snowball/flake-utils";
  };

  # Main output
  outputs =
    # Inputs
    {
      # Special arguement that point the result of output it's self
      self,
      # Main package library
      nixpkgs,
      # Utils lib
      flake-utils,
      ...
    }:
    let
      # Import function form flake utils
      inherit (flake-utils.lib) eachDefaultSystem;

      # Non system specific output
      systemOutputs = {
        # import local library.
        lib = import ./lib;
      };

      # System specific output
      multiSystemOutputs =
        # The system for witch the output is define
        system:
        let
          # Get package for the given system
          pkgs = import nixpkgs { inherit system; };

          # Import packages
          inherit (pkgs)
            coreutils
            mkShell
            nixd
            nixfmt-rfc-style
            gnutar
            ;
          # Get function from this flake lib
          inherit (self.lib)
            nushellScript
            nushellWith
            ;
          # Get package from this flake packages
          inherit (self.packages.${system})
            oci-mgmt
            nushell
            ;
        in
        {
          # List of exported packages
          packages = {
            # Default main pacakge to the application
            default = oci-mgmt;
            # Define a new nushell with required depencies
            nushell = nushellWith {
              inherit pkgs;
              deps = [
                gnutar # tar
                coreutils # chmod
              ];
            };
            # Main package
            oci-mgmt = nushellScript {
              # Use custom nushell
              inherit pkgs nushell;

              name = "oci-mgmt";
              # Get source of the shell script
              text = builtins.readFile ./src/main.nu;
            };
          };

          # Simple dev shell
          devShells.default = mkShell {
            buildInputs = [
              # The curstom nushell with required library
              nushell
              # To format nix
              nixfmt-rfc-style
              # LSP for nix
              nixd
            ];
          };
        };
    in
    # Merge the system output and system spécific output (map for each system type)
    (systemOutputs // eachDefaultSystem multiSystemOutputs);
}
