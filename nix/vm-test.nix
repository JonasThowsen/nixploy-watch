{ pkgs, nixployWatchModule }:

let
  # A throwaway age identity and a secrets file encrypted to it, built at
  # evaluation time the way an operator would with `sops --encrypt`.
  secrets =
    pkgs.runCommand "nixploy-watch-test-secrets"
      {
        nativeBuildInputs = [
          pkgs.age
          pkgs.sops
        ];
      }
      ''
        mkdir $out
        age-keygen -o $out/key.txt 2>/dev/null
        recipient=$(age-keygen -y $out/key.txt)
        printf 'TYPESAFE_API_KEY=ts-test-key\nRESEND_API_KEY=re-test-key\n' > plain.env
        sops --encrypt --age "$recipient" --input-type dotenv --output-type dotenv plain.env > $out/secrets.env
      '';

  image = pkgs.dockerTools.buildImage {
    name = "noisy-app";
    tag = "latest";
    copyToRoot = [ pkgs.busybox ];
    config.Cmd = [
      "sh"
      "-c"
      "echo booting; while true; do echo 'ERROR worker killed by OOM'; sleep 1; done"
    ];
  };

  healthyImage = pkgs.dockerTools.buildImage {
    name = "quiet-app";
    tag = "latest";
    copyToRoot = [ pkgs.busybox ];
    config.Cmd = [
      "sh"
      "-c"
      "while true; do echo 'GET /health 200'; sleep 1; done"
    ];
  };
in
pkgs.testers.runNixOSTest {
  name = "nixploy-watch";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ nixployWatchModule ];
      virtualisation.memorySize = 2048;
      virtualisation.podman.enable = true;

      users.users.nixploy = {
        isNormalUser = true;
        uid = 1000;
        linger = true;
      };

      systemd.services.fake-apis = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${./fake-apis.py}";
      };

      services.nixploy-watch = {
        enable = true;
        secretsFile = "${secrets}/secrets.env";
        ageKeyFile = "/home/nixploy/age-key.txt";
        to = [ "ops@example.test" ];
        from = "nixploy-watch <alerts@example.test>";
        endpoints = {
          typesafe = "http://127.0.0.1:8080/v1/systemone";
          resend = "http://127.0.0.1:8080/emails";
        };
      };
    };

  testScript = ''
    import json

    def as_nixploy(command):
        return machine.succeed(f"su - nixploy -c {command!r}")

    def start_watch():
        machine.succeed("systemctl --user -M nixploy@ start --wait nixploy-watch.service")

    def emails():
        machine.succeed("touch /tmp/emails.jsonl")
        return [json.loads(line) for line in machine.succeed("cat /tmp/emails.jsonl").splitlines()]

    machine.wait_for_unit("fake-apis.service")
    machine.wait_for_unit("user@1000.service")
    machine.wait_for_unit("default.target", "nixploy")
    machine.wait_for_open_port(8080)
    machine.succeed("install -o nixploy -m 0400 ${secrets}/key.txt /home/nixploy/age-key.txt")

    with subtest("the timer runs the first check by itself"):
        machine.wait_for_unit("nixploy-watch.timer", "nixploy")
        machine.wait_until_succeeds(
            "journalctl _SYSTEMD_USER_UNIT=nixploy-watch.service --no-pager"
            " | grep -q 'no nixploy-managed containers found'",
            timeout=120,
        )
        assert emails() == []

    labels = (
        "--label io.nixploy.managed=true --label io.nixploy.project=shop "
        "--label io.nixploy.target=production --label io.nixploy.revision=abc123"
    )
    as_nixploy("podman load -i ${image}")
    as_nixploy("podman load -i ${healthyImage}")
    as_nixploy(f"podman run -d --name nixploy-shop-1a2b-production-blue {labels} noisy-app:latest")
    as_nixploy(
        "podman run -d --name nixploy-blog-9f8e-production "
        "--label io.nixploy.managed=true --label io.nixploy.project=blog "
        "--label io.nixploy.target=production quiet-app:latest"
    )
    as_nixploy("podman run -d --name unrelated noisy-app:latest")
    machine.sleep(3)

    with subtest("unhealthy application is emailed with decrypted keys"):
        start_watch()
        sent = emails()
        assert len(sent) == 1, sent
        email = sent[0]
        assert email["to"] == ["ops@example.test"], email
        assert email["subject"].startswith("[nixploy-watch] shop/production: "), email
        assert "crash" in email["subject"], email
        assert "killed by OOM" in email["text"], email
        assert "revision abc123" in email["text"], email
        authorization = machine.succeed("cat /tmp/authorization.log")
        assert "/v1/systemone Bearer ts-test-key" in authorization, authorization
        assert "/emails Bearer re-test-key" in authorization, authorization

    with subtest("healthy and unlabelled containers are not emailed"):
        assert all("blog" not in e["subject"] for e in sent)
        journal = machine.succeed("journalctl _SYSTEMD_USER_UNIT=nixploy-watch.service --no-pager")
        assert "blog/production nixploy-blog-9f8e-production:" in journal, journal
        assert "unrelated" not in journal, journal

    with subtest("state is kept and the cooldown holds back a repeat"):
        machine.succeed("test -s /home/nixploy/.local/state/nixploy-watch/state.json")
        machine.sleep(2)
        start_watch()
        assert len(emails()) == 1
        journal = machine.succeed("journalctl _SYSTEMD_USER_UNIT=nixploy-watch.service --no-pager")
        assert "shop/production: alert held back by cooldown" in journal, journal

    with subtest("secrets never reach argv or the journal"):
        machine.fail("journalctl --no-pager | grep -e ts-test-key -e re-test-key")
  '';
}
