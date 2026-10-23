{
  description = "kubewall — single-binary Kubernetes dashboard with multi-cluster management";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: nixpkgs.legacyPackages.${system};
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;

          # Yarn 1 offline mirror built from the committed client/yarn.lock.
          yarnCache = pkgs.fetchYarnDeps {
            yarnLock = ./client/yarn.lock;
            hash = "sha256-CSjhRFhgVBPnK3qBzPCOu7H9xiB66l4B2DzFS71o4K8=";
          };

          # Vite/tsc build of the web client. Produces the static assets that
          # the Go binary embeds at compile time (mirrors the goreleaser hook:
          # `yarn --cwd client run build`).
          kubewall-client = pkgs.stdenv.mkDerivation {
            pname = "kubewall-client";
            version = "dev";
            src = ./client;

            nativeBuildInputs = with pkgs; [
              nodejs_22
              yarn
              yarnConfigHook
              yarnBuildHook
            ];

            yarnOfflineCache = yarnCache;

            installPhase = ''
              runHook preInstall
              cp -rT dist $out
              runHook postInstall
            '';
          };

          # Go backend with the freshly built client embedded into
          # backend/routes/static (required by `//go:embed static/*` in
          # backend/routes/routes.go). kubectl is wrapped into PATH because
          # handlers/apply/kubectl.go execs it at runtime.
          kubewall = pkgs.buildGoModule {
            pname = "kubewall";
            version = "dev";
            src = ./backend;

            subPackages = [ "." ];
            vendorHash = "sha256-FnsBMyJzZXk9j396b9t39N6q1lFYWGKRjuMoCYGEgpI=";

            ldflags = [
              "-s"
              "-w"
            ];

            nativeBuildInputs = [ pkgs.makeWrapper ];

            postPatch = ''
              mkdir -p routes/static
              cp -rT ${kubewall-client} routes/static
            '';

            postInstall = ''
              mv $out/bin/backend $out/bin/kubewall
              wrapProgram $out/bin/kubewall \
                --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.kubectl ]}
            '';

            # kubewall reads kubeconfigs and opens the browser; pointless under the build sandbox.
            doCheck = false;

            meta = with pkgs.lib; {
              description = "Single-binary Kubernetes dashboard with multi-cluster management & AI integration";
              homepage = "https://github.com/kubewall/kubewall";
              license = licenses.asl20;
              mainProgram = "kubewall";
            };
          };
        in
        {
          inherit kubewall-client kubewall;
          default = kubewall;
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              go
              nodejs_22
              yarn
              kubectl # runtime dependency of the apply handler
              git
            ];
            shellHook = ''
              echo "kubewall dev shell"
              echo "  client:  cd client && yarn install && yarn run dev   (vite on :5173, proxies /api to :7080)"
              echo "  binary:  cd client && yarn install && yarn run build"
              echo "           rm -rf ../backend/routes/static && mv dist ../backend/routes/static"
              echo "           cd ../backend && go run ."
            '';
          };
        }
      );
    };
}
