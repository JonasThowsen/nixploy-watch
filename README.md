# nixploy-watch

Every 15 minutes, on the server where [nixploy](https://github.com/JonasThowsen/nixploy)
runs your containers, nixploy-watch reads the log lines each container wrote
since the last check and asks [Jev](https://docs.typesafe.ai) a set of yes/no
**classifiers** about them. If a classifier marked `email = true` answers yes,
you get an email through [Resend](https://resend.com) quoting the log lines
Jev picked as evidence. Otherwise nothing happens.

It finds containers by nixploy's ownership labels (`io.nixploy.managed`,
`io.nixploy.project`, `io.nixploy.target`), so there is nothing to configure
per application. It only reads Podman; it never starts, stops or removes
anything.

## How a check works

For each nixploy application (`project/target`) on the host:

1. Each running container's logs since its last successful check
   (`podman logs --since`) are merged from stdout and stderr, stripped of
   terminal escapes, redacted with nixploy's credential rules, and messages
   that differ only in numbers are merged and counted. The result is capped at
   250 messages and 48 KB so it fits Jev's context; when it is larger, lines
   that look like problems are kept first.
2. One System One request asks every classifier as a Noul question. For every
   emailing classifier it also asks a Choice over the line ids, which selects
   the line that best shows the problem. The container's state and restarts
   since the last check are part of the state Jev sees.
3. An email is sent when any emailing classifier is at or above the threshold
   (0.5), at most once per cooldown (60 minutes) per application, so an
   ongoing problem does not email every 15 minutes.

If no container of an application is running, the tail of the most recently
started one is classified instead. A failed check (Podman, TypeSafe) is
emailed as "could not be checked" and retried with the same window next time.

## Classifiers

`nixploy-watch classifiers` prints the built-in set:

| name | emails |
| --- | --- |
| crash | yes |
| unhandled_errors | yes |
| dependency_failure | yes |
| failing_requests | yes |
| resource_exhaustion | yes |
| configuration_problem | yes |
| security_event | no (scanners are constant on public servers) |
| noisy_warnings | no |

Classifiers that do not email are still written to the journal and listed in
any email that is sent. To change them, set `services.nixploy-watch.classifiers`
to your own list; it replaces the built-in set:

```nix
services.nixploy-watch.classifiers = [
  {
    name = "payment_failure";
    question = "Does `log` show a payment failing at the payment provider?";
    yes = "A charge, refund or webhook from the payment provider failed or was rejected.";
    no = "Payments succeed, or a customer's card was declined normally.";
    email = true;
  }
  # ...
];
```

## Install on the NixOS host

The watcher runs as a systemd **user** service of the account that owns
nixploy's rootless containers, the target's SSH `user`, so it sees the same
Podman storage. That account needs lingering, which nixploy's reboot guidance
already asks for.

1. Put the API keys in a SOPS-encrypted dotenv, as you do for nixploy
   secrets:

   ```bash
   printf 'TYPESAFE_API_KEY=...\nRESEND_API_KEY=...\n' > plain.env
   sops --encrypt --age "$(age-keygen -y key.txt)" \
     --input-type dotenv --output-type dotenv plain.env > secrets/nixploy-watch.env
   rm plain.env
   ```

2. Make the age identity readable by the container account on the host (not
   via the Nix store), for example `/var/lib/nixploy/.config/sops/age/keys.txt`
   with mode 0400. An SSH ed25519 key works too, via `ageSshKeyFile`.

3. Add the flake and module to the host configuration:

   ```nix
   inputs.nixploy-watch.url = "github:JonasThowsen/nixploy-watch";

   # in nixosSystem modules:
   nixploy-watch.nixosModules.default
   {
     virtualisation.podman.enable = true;
     users.users.nixploy.linger = true;

     services.nixploy-watch = {
       enable = true;
       user = "nixploy";
       secretsFile = ./secrets/nixploy-watch.env;
       ageKeyFile = "/var/lib/nixploy/.config/sops/age/keys.txt";
       to = [ "you@example.com" ];
       from = "nixploy-watch <alerts@your-resend-domain.example>";
     };
   }
   ```

Other options: `intervalMinutes` (15), `cooldownMinutes` (60), `threshold`
(0.5) and `model` (`jev-latest`). Once you have tuned the threshold, pin a
version such as `jev-1.13.0` so an alias update cannot change behaviour
without you noticing.

## Operating it

```bash
# Run a check now, and read what each check concluded
systemctl --user -M nixploy@ start nixploy-watch.service
journalctl _SYSTEMD_USER_UNIT=nixploy-watch.service

# Try it by hand without sending email or saving state
nixploy-watch check --dry-run --state-file /tmp/state.json \
  --secrets secrets/nixploy-watch.env --to you@example.com --from alerts@example.com
```

State lives in `~/.local/state/nixploy-watch/state.json` of the container
account. Deleting it is safe: each container is then checked from 15 minutes
back.

## Development

```bash
nix develop -c dune build @runtest    # unit tests with fake Podman, Jev and Resend
nix flake check -L                    # package + NixOS VM test with real rootless
                                      # Podman, sops and the systemd user timer
```

Log lines leave the host twice: to TypeSafe for classification and, when an
alert fires, to Resend. Both see redacted text only, with the same redaction
nixploy applies to `nixploy logs`.
