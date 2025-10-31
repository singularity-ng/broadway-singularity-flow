{ pkgs ? import <nixpkgs> {} }:
 
pkgs.mkShell {
  buildInputs = [
    pkgs.erlang
    pkgs.elixir_1_19
    pkgs.rebar3
    pkgs.git
  ];
 
  shellHook = ''
    echo "Entering Nix shell with Erlang/Elixir (Elixir 1.19)"
    export MIX_ENV=test
  '';
}