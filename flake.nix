{
  description = "Development environment for swift-capnproto";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      supportedSystems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = (if pkgs.stdenv.hostPlatform.isDarwin then pkgs.mkShellNoCC else pkgs.mkShell) {
            packages = with pkgs;
              [
                capnproto
                cmake
                git
                jq
                ninja
                pkg-config
                ripgrep
              ]
              ++ lib.optionals stdenv.hostPlatform.isLinux [ swift ];

            env = {
              CAPNP_TEST_UPSTREAM_REV = "9aad1331857d2b02158cffdba4d664f71f7f81de";
              SWIFT_DETERMINISTIC_HASHING = "1";
            };

            shellHook = ''
              ${pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
                export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
              ''}
              if ! command -v swift >/dev/null 2>&1; then
                echo "Swift was not found. On macOS, install the Xcode command-line tools." >&2
              fi
            '';
          };
        }
      );
    };
}
