# This file is a toolbox file to parse a .nix directory and make
# 1. a nix overlay
# 2. a shell and a build derivation
with builtins;
let
  get-path = src: f: let local = src + "/.nix/${f}"; in
    if pathExists local then local else ./. + "/${f}";
in
{
  src ? ./., # provide he current directory
  config-file ? get-path src "config.nix",
  fallback-file ? get-path src "fallback-config.nix",
  nixpkgs-file ? get-path src "nixpkgs.nix",
  shellHook-file ? get-path src "shellHook.sh",
  overlays-dir ? get-path src "overlays",
  coq-overlays-dir ? get-path src "coq-overlays",
  ocaml-overlays-dir ? get-path src "ocaml-overlays",
  ci-matrix ? false,
  config ? {},
  override ? {},
  ocaml-override ? {},
  global-override ? {},
  withEmacs ? false,
  print-env ? false,
  do-nothing ? false,
  update-nixpkgs ? false,
  ci-step ? null,
  ci ? (!isNull ci-step),
  inNixShell ? null
}@args:
let
  optionalImport = f: d:
    if (isPath f || isString f) && pathExists f then import f else d;
  do-nothing = (args.do-nothing or false) || update-nixpkgs || ci-matrix;
  initial = {
    config = (optionalImport config-file (optionalImport fallback-file {}))
              // config;
    nixpkgs = optionalImport nixpkgs-file (throw "cannot find nixpkgs");
    pkgs = import initial.nixpkgs {};
    src = src;
    lib = initial.pkgs.coqPackages.lib or tmp-pkgs.lib;
    inherit overlays-dir coq-overlays-dir ocaml-overlays-dir;
    inherit global-override override ocaml-override;
  };
  my-throw = x: throw "Coq nix toolbox error: ${x}";
in
with initial.lib; let 
  inNixShell = args.inNixShell or trivial.inNixShell;
  setup = switch initial.config.format [
    { case = "1.0.0";        out = import ./config-parser-1.0.0 initial; }
    { case = x: !isString x; out = my-throw "config.format must be a string."; }
  ] (my-throw "config.format ${initial.config.format} not supported");
  instances = setup.instances;
  selected-instance = instances."${setup.config.select}";
  shellHook = readFile shellHook-file
      + optionalString print-env "\nprintNixEnv; exit"
      + optionalString update-nixpkgs "\nupdateNixpkgsUnstable; exit"
      + optionalString ci-matrix "\nnixInputs; exit";
  jsonInputs = toJSON (attrNames setup.fixed-input);
  jsonInput  = toJSON selected-instance.input; 
  nix-shell = with selected-instance; this-shell-pkg.overrideAttrs (old: {
    inherit (setup.config) nixpkgs logpath realpath;
    inherit jsonInput jsonInputs shellHook;
    currentDir = initial.src;
    configSubDir = ".nix";
    coq_version = pkgs.coqPackages.coq.coq-version;

    nativeBuildInputs = optionals (!do-nothing)
      (old.propagatedBuildInputs or []);

    buildInputs = optionals (!do-nothing)
      (old.buildInputs or [] ++ optional withEmacs pkgs.emacs);

    propagatedBuildInputs = optionals (!do-nothing)
      (old.propagatedBuildInputs or []);
  });
  nix-ci = step: flatten (mapAttrsToList (_: i: i.ci-pkgs step) instances);
  nix-ci-for = name: step: instances.${name}.ci-pkgs step;
  nix-default = selected-instance.this-pkg;
  nix-auto = switch-if [
    { cond = inNixShell;  out = nix-shell; }
    { cond = ci == true;  out = nix-ci ci-step; }
    { cond = isString ci; out = nix-ci-for ci ci-step; }
  ] nix-default;
  in
nix-shell.overrideAttrs (o: {
  configSubDir = ".";
  passthru = (o.passthru or {})
             // { inherit initial setup shellHook;
                  inherit nix-shell nix-default;
                  inherit nix-ci nix-ci-for nix-auto; };
})
