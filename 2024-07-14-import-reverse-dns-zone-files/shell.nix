let
  pkgs = import <nixpkgs> {};
  stdenv = pkgs.stdenv;

in stdenv.mkDerivation rec {
  name = "import-ptrs";

  buildInputs = with pkgs;[
    ruby_3_2
    openssl
  ];

  shellHook = ''
    export GEM_HOME=$(pwd)/.gems
    export PATH="$GEM_HOME/bin:$PATH"
    gem install bundler
    bundle install
  '';
}