{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkOption types;
  cfg = config.services.nixploy-watch;

  classifierType = types.submodule {
    options = {
      name = mkOption {
        type = types.strMatching "[a-z0-9_]{1,64}";
        description = "Identifier shown in emails and the journal.";
      };
      question = mkOption {
        type = types.str;
        example = "Does `log` show the application failing to reach its database?";
        description = ''
          The yes/no question Jev answers about each log window. It may refer
          to the state fields `log` and `container` in backticks.
        '';
      };
      yes = mkOption {
        type = types.str;
        description = "What a yes means; also quoted in the alert email.";
      };
      no = mkOption {
        type = types.str;
        description = "What a no means, including look-alikes that are normal.";
      };
      email = mkOption {
        type = types.bool;
        description = ''
          Whether a yes emails the operator. Classifiers that do not email are
          still recorded in the journal and listed in other alerts.
        '';
      };
    };
  };

  classifiersFile = pkgs.writeText "nixploy-watch-classifiers.json" (builtins.toJSON cfg.classifiers);

  arguments = [
    "check"
    "--secrets"
    "${cfg.secretsFile}"
    "--from"
    cfg.from
    "--model"
    cfg.model
    "--threshold"
    (toString cfg.threshold)
    "--cooldown-minutes"
    (toString cfg.cooldownMinutes)
    "--interval-minutes"
    (toString cfg.intervalMinutes)
    "--podman"
    (lib.getExe config.virtualisation.podman.package)
    "--typesafe-url"
    cfg.endpoints.typesafe
    "--resend-url"
    cfg.endpoints.resend
  ]
  ++ lib.concatMap (address: [
    "--to"
    address
  ]) cfg.to
  ++ lib.optionals (cfg.classifiers != null) [
    "--classifiers"
    "${classifiersFile}"
  ];
in
{
  options.services.nixploy-watch = {
    enable = lib.mkEnableOption ''
      a periodic check that asks Jev whether nixploy-managed containers on
      this host are healthy and emails through Resend when they are not
    '';

    package = mkOption {
      type = types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "nixploy-watch.packages.\${system}.default";
      description = "The nixploy-watch package.";
    };

    user = mkOption {
      type = types.str;
      default = "nixploy";
      description = ''
        The account whose rootless Podman runs nixploy's containers, normally
        the target's SSH `user`. The watcher runs as a systemd user service of
        this account, which therefore needs lingering.
      '';
    };

    secretsFile = mkOption {
      type = types.path;
      example = lib.literalExpression "./secrets/nixploy-watch.env";
      description = ''
        SOPS-encrypted dotenv defining TYPESAFE_API_KEY and RESEND_API_KEY. It
        stays encrypted in the Nix store and is decrypted with `sops` at every
        run, the same way nixploy decrypts target secrets.
      '';
    };

    ageKeyFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/var/lib/nixploy/.config/sops/age/keys.txt";
      description = ''
        Age identity that decrypts `secretsFile`, readable by `user`. A string
        rather than a path so the key never enters the Nix store.
      '';
    };

    ageSshKeyFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Alternatively, an SSH ed25519 private key readable by `user` that sops
        converts to an age identity.
      '';
    };

    to = mkOption {
      type = types.nonEmptyListOf types.str;
      example = [ "ops@example.com" ];
      description = "Alert recipients.";
    };

    from = mkOption {
      type = types.str;
      example = "nixploy-watch <alerts@example.com>";
      description = "Sender; its domain must be verified in Resend.";
    };

    classifiers = mkOption {
      type = types.nullOr (types.nonEmptyListOf classifierType);
      default = null;
      description = ''
        The questions Jev answers about every log window, and whether a yes
        emails. `null` uses the built-in set; print it with
        `nixploy-watch classifiers` to start a custom list.
      '';
    };

    intervalMinutes = mkOption {
      type = types.ints.positive;
      default = 15;
      description = "Minutes between checks.";
    };

    cooldownMinutes = mkOption {
      type = types.ints.unsigned;
      default = 60;
      description = ''
        Minimum minutes between two emails about the same application, so a
        lasting problem does not email at every check. 0 disables it.
      '';
    };

    threshold = mkOption {
      type = types.numbers.between 0.01 1;
      default = 0.5;
      description = "Classifier probability at or above which the answer counts as yes.";
    };

    model = mkOption {
      type = types.str;
      default = "jev-latest";
      description = ''
        TypeSafe model. Pin a versioned id such as `jev-1.13.0` after tuning
        the threshold, so an alias update cannot change behaviour silently.
      '';
    };

    endpoints = {
      typesafe = mkOption {
        type = types.str;
        default = "https://api.typesafe.ai/v1/systemone";
        internal = true;
      };
      resend = mkOption {
        type = types.str;
        default = "https://api.resend.com/emails";
        internal = true;
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.virtualisation.podman.enable;
        message = "services.nixploy-watch reads nixploy's containers and requires virtualisation.podman.enable";
      }
      {
        assertion = config.users.users.${cfg.user}.linger or false;
        message = "services.nixploy-watch runs as a user service and requires users.users.${cfg.user}.linger = true";
      }
      {
        assertion = (cfg.ageKeyFile != null) != (cfg.ageSshKeyFile != null);
        message = "services.nixploy-watch needs exactly one of ageKeyFile or ageSshKeyFile";
      }
    ];

    systemd.user.services.nixploy-watch = {
      description = "Classify nixploy container logs with Jev and email about problems";
      unitConfig.ConditionUser = cfg.user;
      # Rootless Podman needs the setuid newuidmap/newgidmap wrappers.
      path = [ "/run/wrappers" ];
      environment =
        lib.optionalAttrs (cfg.ageKeyFile != null) { SOPS_AGE_KEY_FILE = cfg.ageKeyFile; }
        // lib.optionalAttrs (cfg.ageSshKeyFile != null) {
          SOPS_AGE_SSH_PRIVATE_KEY_FILE = cfg.ageSshKeyFile;
        };
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "nixploy-watch";
        ExecStart = lib.escapeShellArgs ([ (lib.getExe cfg.package) ] ++ arguments);
      };
    };

    systemd.user.timers.nixploy-watch = {
      description = "Run nixploy-watch every ${toString cfg.intervalMinutes} minutes";
      wantedBy = [ "timers.target" ];
      unitConfig.ConditionUser = cfg.user;
      timerConfig = {
        OnStartupSec = "2min";
        OnUnitActiveSec = "${toString cfg.intervalMinutes}min";
      };
    };
  };
}
