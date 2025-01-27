rec {
  nushellLibPath = "/lib/nushell";

  makeNushellPath = builtins.map (path: "${path}${nushellLibPath}");

  nushellLib =
    {
      pkgs,
      name,
      src,
      deps ? [],
      root ? "",
    }:
    let
      inherit (pkgs.stdenv) mkDerivation;
    in
    mkDerivation {
      inherit name src;

      depsTargetTarget = deps;

      phases = [
        "unpackPhase"
        "installPhase"
      ];

      installPhase = ''
        mkdir -p $out${nushellLibPath}
        cp -r $src/${root}/${name} $out${nushellLibPath}
      '';
    };

  nushellWith =
    {
      pkgs,
      libraries ? [ ],
      deps ? [ ],
      env ? "",
      config ? "",
    }:
    let
      inherit (pkgs) lib writeTextFile writeText;
      inherit (lib) concatStringsSep flatten;

      allDeps = deps ++ (flatten (builtins.map (lib: lib.depsTargetTarget) libraries));
      paths = builtins.map (path: "${path}/bin") allDeps;

      config-nu = writeText "config.nu" config;
      env-nu = writeText "env.nu" ''
        $env.NU_LIB_DIRS = [${concatStringsSep " " ([ "." ] ++ (makeNushellPath libraries))}]
        $env.PATH = ($env.PATH | split row ":")
        $env.PATH = ($env.PATH | prepend [${concatStringsSep " " paths}])

        ${env}
      '';
    in
    writeTextFile {
      name = "nushell-wrapper";
      text = ''
        #!${pkgs.nushell}/bin/nu

        def --wrapped main [...args] {
          ${pkgs.nushell}/bin/nu --config ${config-nu} --env-config ${env-nu} ...$args
        }
      '';
      derivationArgs = {
      };
      executable = true;
      destination = "/bin/nu";
    };

  nushellScript =
    {
      pkgs,
      name,
      text,
      ...
    }@inputs:
    let
      inherit (pkgs) writeTextFile;

      nushell = if inputs ? nushell then inputs.nushell else nushellWith (inputs // { inherit pkgs; });
    in
    writeTextFile {
      inherit name;

      executable = true;

      destination = "/bin/${name}";
      text = ''
        #!${nushell}/bin/nu
        ${text}
      '';

      checkPhase = ''
        ${nushell}/bin/nu -c "nu-check $out/bin/${name}"
      '';
    };
}
