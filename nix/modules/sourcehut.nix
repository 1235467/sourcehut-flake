{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    concatMapStringsSep
    mkDefault
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    mkPackageOption
    optional
    optionalAttrs
    types
    ;

  cfg = config.services.srht;

  sourcehutPkgs = import ../packages { inherit pkgs; };

  domain = if cfg.domain != null then cfg.domain else config.networking.domain;

  settingsFormat = pkgs.formats.ini {
    listToValue = concatMapStringsSep "," (lib.generators.mkValueStringDefault { });
    mkKeyValue =
      k: v:
      lib.optionalString (v != null) (
        lib.generators.mkKeyValueDefault {
          mkValueString =
            v:
            if lib.isBool v then
              (if v then "yes" else "no")
            else
              lib.generators.mkValueStringDefault { } v;
        } "=" k v
      );
  };

  iniValueType = types.nullOr (
    types.oneOf [
      types.bool
      types.int
      types.float
      types.str
      types.path
    ]
  );

  iniSectionType = types.attrsOf iniValueType;

  mkIniOption = attrs: mkOption ({ type = iniValueType; default = null; } // attrs);

  mkIniSection = options: types.submodule {
    freeformType = iniSectionType;
    inherit options;
  };

  # Typed with the nixpkgs nginx virtual-host options, so users get option
  # checking and completion for the configuration merged into our vhosts.
  nginxVhostOptions = import (pkgs.path + "/nixos/modules/services/web-servers/nginx/vhost-options.nix");

  # Declared settings options default to null; drop them (and sections that
  # end up empty) before rendering so the generated ini only contains keys
  # that are actually set.
  renderedSettings = lib.filterAttrs (name: section: section != { }) (
    lib.mapAttrs (_: lib.filterAttrs (_: v: v != null)) cfg.settings
  );

  python = pkgs.python3.withPackages (
    ps:
    [
      sourcehutPkgs.srht
      ps.gunicorn
    ]
    ++ optional cfg.meta.enable sourcehutPkgs.metasrht.python
    ++ optional cfg.git.enable sourcehutPkgs.gitsrht.python
    ++ optional cfg.meta.enable ps.celery
  );

  assets = pkgs.buildEnv {
    name = "sourcehut-assets";
    paths = [
      sourcehutPkgs.srht
    ]
    ++ optional cfg.meta.enable sourcehutPkgs.metasrht
    ++ optional cfg.git.enable sourcehutPkgs.gitsrht;
    pathsToLink = [ "/share/sourcehut" ];
  };

  sshCommand = "${sourcehutPkgs.sourcehut-ssh}/bin/sourcehut-ssh \"%u\" \"%h\" \"%t\" \"%k\"";

  configFile = config.environment.etc."sr.ht/config.ini".source;

  protectedServiceConfig = {
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    RestrictSUIDSGID = true;
    RestrictRealtime = true;
    RestrictAddressFamilies = [
      "AF_UNIX"
      "AF_INET"
      "AF_INET6"
    ];
    LockPersonality = true;
    SystemCallArchitectures = "native";
  };

  mkService =
    service:
    extra:
    {
      after = [
        "network.target"
        "sourcehut-migrate-${service}.service"
      ]
      ++ optional config.services.postgresql.enable "postgresql.target";
      restartTriggers = [ configFile ];
    }
    // extra
    // {
      serviceConfig = protectedServiceConfig // {
        Restart = "always";
      } // (extra.serviceConfig or { });
    };
in
{
  options.services.srht = {
    enable = mkEnableOption "SourceHut (git.sr.ht and meta.sr.ht)";

    settings = mkOption {
      type = types.submodule {
        freeformType = types.attrsOf iniSectionType;
        options = {
          "sr.ht" = mkOption {
            type = mkIniSection {
              global-domain = mkIniOption {
                description = "Global domain of the instance; set from {option}`services.srht.domain`.";
                example = "example.com";
              };
              environment = mkIniOption {
                description = "Values other than `production` add a banner to each page.";
                example = "production";
              };
              service-key = mkIniOption {
                description = "Key encrypting session cookies. Generate with `sr.ht-keygen service`. Required.";
              };
              network-key = mkIniOption {
                description = "Key encrypting internal messages, e.g. between services and for SSH dispatch. Generate with `sr.ht-keygen network`. Required.";
              };
              redis-host = mkIniOption {
                description = "Redis-compatible URL used for caching and sessions (Redis, Valkey, DragonFly, `rediss://`, `unix://`, sentinel lists). Not managed by this module. Required.";
                example = "redis://127.0.0.1:6379/0";
              };
              assets = mkIniOption {
                description = "Asset directory; set automatically to the directory packaged by this module.";
              };
            };
            default = { };
          };

          "webhooks" = mkOption {
            type = mkIniSection {
              private-key = mkIniOption {
                description = "Base64-encoded Ed25519 key signing webhook payloads. Generate with `sr.ht-keygen webhook`. Required.";
              };
            };
            default = { };
          };

          "meta.sr.ht" = mkOption {
            type = mkIniSection {
              api-internal-origin = mkIniOption {
                description = "Address the GraphQL API is reached at internally (frontends, SSH dispatcher, ...). Defaults to the loopback API port; `origin` is used when unset.";
                example = "http://127.0.0.1:5100";
              };
              connection-string = mkIniOption {
                description = "PostgreSQL connection URL for meta.sr.ht, including credentials. Databases are not managed by this module. Required.";
                example = "postgresql://meta:password@127.0.0.1/meta.sr.ht";
              };
              webhooks = mkIniOption {
                description = "Celery broker URL for the meta.sr.ht webhook delivery worker. Required.";
                example = "redis://127.0.0.1:6379/1";
              };
              origin = mkIniOption {
                description = "URL meta.sr.ht is served at; defaults to `https://meta.<domain>`.";
                example = "https://meta.example.com";
              };
              migrate-on-upgrade = mkIniOption {
                description = "Whether database migrations are applied on boot (`sourcehut-migrate -a`).";
                example = "yes";
              };
            };
            default = { };
          };

          "meta.sr.ht::api" = mkOption {
            type = mkIniSection {
              internal-ipnet = mkIniOption {
                description = "Subnets permitted to use internal API authentication.";
                example = "127.0.0.0/8,::1/128";
              };
            };
            default = { };
          };

          "meta.sr.ht::settings" = mkOption {
            type = mkIniSection {
              registration = mkIniOption {
                description = "Whether public registration is permitted.";
                example = "no";
              };
              onboarding-redirect = mkIniOption {
                description = "Where new users are redirected after registration; defaults to `https://meta.<domain>`.";
                example = "https://meta.example.com";
              };
              welcome-emails = mkIniOption {
                description = "Whether stock welcome emails are sent after signup.";
                example = "no";
              };
            };
            default = { };
          };

          "git.sr.ht" = mkOption {
            type = mkIniSection {
              api-internal-origin = mkIniOption {
                description = "Address the GraphQL API is reached at internally (frontends, SSH dispatcher, ...). Defaults to the loopback API port; `origin` is used when unset.";
                example = "http://127.0.0.1:5101";
              };
              connection-string = mkIniOption {
                description = "PostgreSQL connection URL for git.sr.ht, including credentials. Databases are not managed by this module. Required.";
                example = "postgresql://git:password@127.0.0.1/git.sr.ht";
              };
              origin = mkIniOption {
                description = "URL git.sr.ht is served at; defaults to `https://git.<domain>`.";
                example = "https://git.example.com";
              };
              outgoing-domain = mkIniOption {
                description = "Domain used for outgoing links in patchsets; defaults to `https://git.<domain>`.";
                example = "https://git.example.com";
              };
              repos = mkIniOption {
                description = "Path to git repositories on disk; set from {option}`services.srht.git.repos`.";
              };
              shell = mkIniOption {
                description = "Shell dispatched to for authenticated SSH sessions; set from the packaged git.sr.ht.";
              };
              post-update-script = mkIniOption {
                description = "Hook installed into every repository; set from the packaged git.sr.ht.";
              };
              enable-dispatch = mkIniOption {
                description = "Whether this service is handled by the unified SSH dispatcher (`sourcehut-ssh`).";
                example = true;
              };
              migrate-on-upgrade = mkIniOption {
                description = "Whether database migrations are applied on boot (`sourcehut-migrate -a`).";
                example = "yes";
              };
            };
            default = { };
          };

          "git.sr.ht::api" = mkOption {
            type = mkIniSection {
              internal-ipnet = mkIniOption {
                description = "Subnets permitted to use internal API authentication.";
                example = "127.0.0.0/8,::1/128";
              };
            };
            default = { };
          };

          "mail" = mkOption {
            type = mkIniSection {
              smtp-host = mkIniOption {
                description = "Outgoing SMTP host. Without it, mail sending fails.";
                example = "smtp.example.com";
              };
              smtp-port = mkIniOption {
                description = "Outgoing SMTP port.";
                example = 587;
              };
              smtp-user = mkIniOption { description = "Outgoing SMTP user."; };
              smtp-password = mkIniOption { description = "Outgoing SMTP password."; };
              smtp-from = mkIniOption {
                description = "Sender address of outgoing mail.";
                example = "noreply@example.com";
              };
              smtp-encryption = mkIniOption {
                description = "SMTP encryption mode.";
                example = "starttls";
              };
              smtp-auth = mkIniOption {
                description = "SMTP authentication mode.";
                example = "plain";
              };
              error-to = mkIniOption { description = "Address receiving application exceptions."; };
              error-from = mkIniOption { description = "Address sending application exceptions."; };
              pgp-privkey = mkIniOption {
                description = "Path to the (passwordless) OpenPGP private key used to sign outgoing mail; keep it outside the Nix store.";
              };
              pgp-pubkey = mkIniOption { description = "Path to or inline OpenPGP public key."; };
              pgp-key-id = mkIniOption { description = "OpenPGP key ID string."; };
            };
            default = { };
          };

          "objects" = mkOption {
            type = mkIniSection {
              s3-upstream = mkIniOption {
                description = "S3-compatible object storage endpoint (optional).";
                example = "https://s3.example.com";
              };
              s3-access-key = mkIniOption { description = "Access key for object storage."; };
              s3-secret-key = mkIniOption {
                description = "Path to the object storage secret key, outside the Nix store.";
              };
            };
            default = { };
          };
        };
      };
      default = { };
      description = ''
        Configuration written to {file}`/etc/sr.ht/config.ini`, following the
        layout of the upstream
        [git.sr.ht](https://git.sr.ht/~sircmpwn/git.sr.ht/tree/master/item/config.example.ini)
        and [meta.sr.ht](https://git.sr.ht/~sircmpwn/meta.sr.ht/tree/master/item/config.example.ini)
        `config.example.ini` files. Frequently used keys have typed options
        with documentation and examples; any other upstream key can be set
        through the freeform attribute set, e.g.
        {option}`services.srht.settings."git.sr.ht".api-origin`.
      '';
    };

    domain = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        The global domain of the SourceHut instance.
        Defaults to {option}`networking.domain`.
        Sets {option}`services.srht.settings.sr.ht.global-domain` and derives
        the `origin` defaults for meta.sr.ht and git.sr.ht.
      '';
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address the web and API services bind to.";
    };

    meta = {
      enable = mkEnableOption "meta.sr.ht, the account management service";

      package = mkPackageOption sourcehutPkgs "metasrht" { };

      user = mkOption {
        type = types.str;
        default = "meta";
        description = "User for meta.sr.ht.";
      };

      group = mkOption {
        type = types.str;
        default = "meta";
        description = "Group for meta.sr.ht.";
      };

      port = mkOption {
        type = types.port;
        default = 5000;
        description = "Port the meta.sr.ht web service listens on.";
      };

      apiPort = mkOption {
        type = types.port;
        default = 5100;
        description = ''
          Port the meta.sr.ht API listens on. Used by the generated nginx
          `/query` location and by the default internal API origin
          ({option}`services.srht.settings."meta.sr.ht".api-internal-origin`).
        '';
      };
    };

    git = {
      enable = mkEnableOption "git.sr.ht, the git repository hosting service";

      package = mkPackageOption sourcehutPkgs "gitsrht" { };

      user = mkOption {
        type = types.str;
        default = "git";
        description = ''
          User for git.sr.ht, also used for SSH access to git repositories.
        '';
      };

      group = mkOption {
        type = types.str;
        default = "git";
        description = "Group for git.sr.ht.";
      };

      port = mkOption {
        type = types.port;
        default = 5001;
        description = "Port the git.sr.ht web service listens on.";
      };

      apiPort = mkOption {
        type = types.port;
        default = 5101;
        description = ''
          Port the git.sr.ht API listens on. Used by the generated nginx
          `/query` location and by the default internal API origin
          ({option}`services.srht.settings."git.sr.ht".api-internal-origin`).
        '';
      };

      repos = mkOption {
        type = types.path;
        default = "/var/lib/git";
        description = ''
          Path to git repositories on disk; also the git user's home.
          Sets {option}`services.srht.settings."git.sr.ht".repos`.
        '';
      };

      gitPackage = mkPackageOption pkgs "git" { };

      manageSshd = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether to configure sshd's AuthorizedKeysCommand for SourceHut's
          SSH dispatcher. Disable this when AuthorizedKeysCommand is managed
          elsewhere and needs to be chained manually.
        '';
      };

      fcgiwrap.prefork = mkOption {
        type = types.ints.positive;
        default = 4;
        description = "Number of fcgiwrap processes preforked for HTTP(S) cloning.";
      };
    };

    nginx.virtualHost = mkOption {
      type = types.submodule nginxVhostOptions;
      default = { };
      description = ''
        Configuration merged into the virtual hosts this module generates for
        `meta.<domain>` and `git.<domain>`, typed with the nginx virtual host
        options from nixpkgs (so `enableACME`, `sslCertificate`, `locations`,
        ... can be set with checking and completion). The module only
        contributes vhost rules; enabling and configuring nginx itself is
        left to the user. TLS via ACME is enabled by default in the generated
        vhosts, so {option}`security.acme.acceptTerms` and
        {option}`security.acme.defaults.email` should be set.
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = domain != null;
          message = ''
            services.srht.domain (or networking.domain) must be set; it is
            used for settings."sr.ht".global-domain and the service origins.
          '';
        }
        {
          assertion = cfg.settings."sr.ht".service-key != null;
          message = ''
            services.srht.settings."sr.ht".service-key must be set, generate
            one with `sr.ht-keygen service`.
          '';
        }
        {
          assertion = cfg.settings."sr.ht".network-key != null;
          message = ''
            services.srht.settings."sr.ht".network-key must be set, generate
            one with `sr.ht-keygen network`.
          '';
        }
        {
          assertion = cfg.settings."webhooks".private-key != null;
          message = ''
            services.srht.settings."webhooks".private-key must be set,
            generate one with `sr.ht-keygen webhook`.
          '';
        }
        {
          assertion = cfg.settings."sr.ht".redis-host != null;
          message = ''
            services.srht.settings."sr.ht".redis-host must be set to point at
            your Redis-compatible backend (Redis, Valkey, DragonFly, ...).
          '';
        }
        {
          assertion = !cfg.meta.enable || cfg.settings."meta.sr.ht".connection-string != null;
          message = ''
            services.srht.settings."meta.sr.ht".connection-string must be set
            to the PostgreSQL connection URL of the meta.sr.ht database,
            including credentials, for example
            "postgresql://meta:password@127.0.0.1/meta.sr.ht".
          '';
        }
        {
          assertion = !cfg.git.enable || cfg.settings."git.sr.ht".connection-string != null;
          message = ''
            services.srht.settings."git.sr.ht".connection-string must be set
            to the PostgreSQL connection URL of the git.sr.ht database,
            including credentials, for example
            "postgresql://git:password@127.0.0.1/git.sr.ht".
          '';
        }
        {
          assertion = !cfg.meta.enable || cfg.settings."meta.sr.ht".webhooks != null;
          message = ''
            services.srht.settings."meta.sr.ht".webhooks must be set to the
            Celery broker URL used by the meta.sr.ht webhook delivery worker,
            for example "redis://127.0.0.1:6379/1".
          '';
        }
        {
          assertion =
            !(cfg.git.enable && cfg.git.manageSshd)
            || config.services.openssh.authorizedKeysCommand == sshCommand;
          message = ''
            Another module has configured services.openssh.authorizedKeysCommand,
            so SourceHut's SSH dispatcher cannot be installed.
            Set services.srht.git.manageSshd = false and chain the dispatcher
            (${sourcehutPkgs.sourcehut-ssh}/bin/sourcehut-ssh) manually.
          '';
        }
      ];

      services.srht.settings = mkMerge [
        {
          "sr.ht" = {
            environment = mkDefault "production";
            global-domain = mkDefault domain;
            assets = mkDefault "${assets}";
          };
        }
        (mkIf cfg.meta.enable {
          "meta.sr.ht".api-internal-origin = mkDefault "http://127.0.0.1:${toString cfg.meta.apiPort}";
        })
        (mkIf cfg.git.enable {
          "git.sr.ht".api-internal-origin = mkDefault "http://127.0.0.1:${toString cfg.git.apiPort}";
        })
        (optionalAttrs (domain != null) {
          "meta.sr.ht".origin = mkDefault "https://meta.${domain}";
          "git.sr.ht".origin = mkDefault "https://git.${domain}";
          "git.sr.ht".outgoing-domain = mkDefault "https://git.${domain}";
          "meta.sr.ht::settings".onboarding-redirect = mkDefault "https://meta.${domain}";
        })
      ];

      environment.etc."sr.ht/config.ini".source = settingsFormat.generate "sourcehut-config.ini" renderedSettings;

      environment.systemPackages = [
        sourcehutPkgs.sourcehut-migrate
      ];

      systemd.tmpfiles.rules = [
        "f /var/log/sourcehut-ssh.log 0644 root root -"
      ];
    }

    (mkIf cfg.meta.enable (mkMerge [
      {
        users.users.${cfg.meta.user} = {
          isSystemUser = mkDefault true;
          group = mkDefault cfg.meta.group;
          home = mkDefault "/var/lib/sourcehut/meta.sr.ht";
          description = mkDefault "meta.sr.ht service user";
        };

        users.groups.${cfg.meta.group} = { };

        services.srht.settings = {
          "meta.sr.ht".migrate-on-upgrade = mkDefault "yes";
          "meta.sr.ht::api".internal-ipnet = mkDefault "127.0.0.0/8,::1/128";
        };

        systemd.services."sourcehut-migrate-meta" = {
          description = "meta.sr.ht database initialization and migration";

          wantedBy = [ "multi-user.target" ];
          before = [
            "meta.sr.ht.service"
            "meta.sr.ht-api.service"
            "meta.sr.ht-webhooks.service"
          ];
          after = optional config.services.postgresql.enable "postgresql.target";
          requires = optional config.services.postgresql.enable "postgresql.target";

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = cfg.meta.user;
            Group = cfg.meta.group;
            StateDirectory = "sourcehut/meta.sr.ht";
          };

          script = ''
            state=/var/lib/sourcehut/meta.sr.ht
            if [ ! -e "$state/db-initialized" ]; then
              ${sourcehutPkgs.sourcehut-migrate}/bin/sourcehut-migrate meta.sr.ht init
              touch "$state/db-initialized"
            fi
            ${sourcehutPkgs.sourcehut-migrate}/bin/sourcehut-migrate -a meta.sr.ht
          '';
        };

        systemd.services."meta.sr.ht" = mkService "meta" {
          description = "meta.sr.ht web service";
          wantedBy = [ "multi-user.target" ];
          requires = optional config.services.postgresql.enable "postgresql.target";
          serviceConfig = {
            User = cfg.meta.user;
            Group = cfg.meta.group;
            StateDirectory = "sourcehut/meta.sr.ht";
            ExecStart = "${python}/bin/gunicorn metasrht.app:app --name meta.sr.ht --bind ${cfg.listenAddress}:${toString cfg.meta.port} --workers 1 --timeout 120 --log-level info";
          };
        };

        systemd.services."meta.sr.ht-api" = mkService "meta" {
          description = "meta.sr.ht API service";
          wantedBy = [ "multi-user.target" ];
          requires = optional config.services.postgresql.enable "postgresql.target";
          serviceConfig = {
            User = cfg.meta.user;
            Group = cfg.meta.group;
            ExecStart = "${cfg.meta.package}/bin/meta.sr.ht-api -b ${cfg.listenAddress}:${toString cfg.meta.apiPort}";
          };
        };

        systemd.services."meta.sr.ht-webhooks" = mkService "meta" {
          description = "meta.sr.ht webhook delivery service";
          wantedBy = [ "multi-user.target" ];
          requires = optional config.services.postgresql.enable "postgresql.target";
          serviceConfig = {
            User = cfg.meta.user;
            Group = cfg.meta.group;
            ExecStart = "${python}/bin/celery --app metasrht.webhooks worker --loglevel=info";
          };
        };

        systemd.services."meta.sr.ht-daily" = {
          description = "meta.sr.ht daily maintenance tasks";
          restartTriggers = [ configFile ];
          serviceConfig = protectedServiceConfig // {
            Type = "oneshot";
            User = cfg.meta.user;
            Group = cfg.meta.group;
            ExecStart = "${python}/bin/meta.sr.ht-daily";
          };
        };

        systemd.timers."meta.sr.ht-daily" = {
          wantedBy = [ "timers.target" ];
          timerConfig.OnCalendar = "daily";
        };

        environment.systemPackages = [
          (pkgs.writeShellScriptBin "meta.sr.ht-manageuser" ''
            exec ${pkgs.sudo}/bin/sudo -u ${cfg.meta.user} \
              ${python}/bin/meta.sr.ht-manageuser "$@"
          '')
        ];
      }
    ]))

    (mkIf cfg.git.enable (mkMerge [
      {
        users.users.${cfg.git.user} = {
          isSystemUser = mkDefault true;
          group = mkDefault cfg.git.group;
          home = mkDefault cfg.git.repos;
          description = mkDefault "git.sr.ht service user";
        };

        users.groups.${cfg.git.group} = { };

        systemd.tmpfiles.rules = [
          "d ${cfg.git.repos} 0755 ${cfg.git.user} ${cfg.git.group} -"
        ];

        services.srht.settings = {
          "git.sr.ht" = {
            repos = mkDefault "${cfg.git.repos}/";
            post-update-script = mkDefault "${cfg.git.package}/bin/git.sr.ht-update-hook";
            shell = mkDefault "${cfg.git.package}/bin/git.sr.ht-shell";
            enable-dispatch = mkDefault true;
            migrate-on-upgrade = mkDefault "yes";
          };
          "git.sr.ht::api".internal-ipnet = mkDefault "127.0.0.0/8,::1/128";
        };

        services.openssh = mkIf cfg.git.manageSshd {
          enable = mkDefault true;
          authorizedKeysCommand = mkDefault sshCommand;
          authorizedKeysCommandUser = mkDefault "root";
          settings.PermitUserEnvironment = mkDefault "SRHT_*";
        };

        systemd.services."sourcehut-migrate-git" = {
          description = "git.sr.ht database initialization and migration";

          wantedBy = [ "multi-user.target" ];
          before = [
            "git.sr.ht.service"
            "git.sr.ht-api.service"
          ];
          after = optional config.services.postgresql.enable "postgresql.target";
          requires = optional config.services.postgresql.enable "postgresql.target";

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = cfg.git.user;
            Group = cfg.git.group;
            StateDirectory = "sourcehut/git.sr.ht";
          };

          script = ''
            state=/var/lib/sourcehut/git.sr.ht
            if [ ! -e "$state/db-initialized" ]; then
              ${sourcehutPkgs.sourcehut-migrate}/bin/sourcehut-migrate git.sr.ht init
              touch "$state/db-initialized"
            fi
            ${sourcehutPkgs.sourcehut-migrate}/bin/sourcehut-migrate -a git.sr.ht
          '';
        };

        systemd.services."git.sr.ht" = mkService "git" {
          description = "git.sr.ht web service";
          wantedBy = [ "multi-user.target" ];
          requires = optional config.services.postgresql.enable "postgresql.target";
          serviceConfig = {
            User = cfg.git.user;
            Group = cfg.git.group;
            StateDirectory = "sourcehut/git.sr.ht";
            ExecStart = "${python}/bin/gunicorn gitsrht.app:app --name git.sr.ht --bind ${cfg.listenAddress}:${toString cfg.git.port} --workers 1 --timeout 120 --log-level info";
          };
        };

        systemd.services."git.sr.ht-api" = mkService "git" {
          description = "git.sr.ht API service";
          wantedBy = [ "multi-user.target" ];
          requires = optional config.services.postgresql.enable "postgresql.target";
          path = [ cfg.git.gitPackage ];
          serviceConfig = {
            User = cfg.git.user;
            Group = cfg.git.group;
            ExecStart = "${cfg.git.package}/bin/git.sr.ht-api -b ${cfg.listenAddress}:${toString cfg.git.apiPort}";
            ReadWritePaths = [ cfg.git.repos ];
          };
        };

        systemd.services."git.sr.ht-periodic" = {
          description = "git.sr.ht periodic maintenance tasks";
          restartTriggers = [ configFile ];
          path = [ cfg.git.gitPackage ];
          serviceConfig = protectedServiceConfig // {
            Type = "oneshot";
            User = cfg.git.user;
            Group = cfg.git.group;
            ExecStart = "${python}/bin/git.sr.ht-periodic";
            ReadWritePaths = [ cfg.git.repos ];
          };
        };

        systemd.timers."git.sr.ht-periodic" = {
          wantedBy = [ "timers.target" ];
          timerConfig.OnCalendar = "*-*-* *:0/20:00";
        };
      }

      {
        services.fcgiwrap.instances.gitsrht = {
          process.prefork = cfg.git.fcgiwrap.prefork;
          process.user = cfg.git.user;
          process.group = cfg.git.group;
          socket.address = "/run/fcgiwrap-gitsrht.sock";
          socket.user = "nginx";
          socket.group = "nginx";
          socket.mode = "0660";
        };
      }
    ]))

    (mkIf (cfg.meta.enable || cfg.git.enable) {
      services.nginx.virtualHosts = optionalAttrs (domain != null) {
        "meta.${domain}" = mkIf cfg.meta.enable (mkMerge [
          {
            forceSSL = mkDefault true;
            enableACME = mkDefault true;
            locations."/" = {
              proxyPass = mkDefault "http://${cfg.listenAddress}:${toString cfg.meta.port}";
              recommendedProxySettings = mkDefault true;
            };
            locations."/query" = {
              proxyPass = mkDefault "http://${cfg.listenAddress}:${toString cfg.meta.apiPort}";
              recommendedProxySettings = mkDefault true;
            };
            locations."/static" = {
              root = "${assets}";
              extraConfig = ''
                expires 30d;
              '';
            };
          }
          cfg.nginx.virtualHost
        ]);

        "git.${domain}" = mkIf cfg.git.enable (mkMerge [
          {
            forceSSL = mkDefault true;
            enableACME = mkDefault true;
            extraConfig = ''
              client_max_body_size 100m;
            '';
            locations."/" = {
              proxyPass = mkDefault "http://${cfg.listenAddress}:${toString cfg.git.port}";
              recommendedProxySettings = mkDefault true;
            };
            locations."/query" = {
              proxyPass = mkDefault "http://${cfg.listenAddress}:${toString cfg.git.apiPort}";
              recommendedProxySettings = mkDefault true;
            };
            locations."/static" = {
              root = "${assets}";
              extraConfig = ''
                expires 30d;
              '';
            };
            locations."~ ^/([^/]+)/([^/]+)/(HEAD|info/refs|objects/info/.*|git-upload-pack|git-upload-archive).*$" = {
              extraConfig = ''
                fastcgi_pass unix:/run/fcgiwrap-gitsrht.sock;
                fastcgi_param SCRIPT_FILENAME ${cfg.git.package}/bin/git.sr.ht-http-clone;
                fastcgi_param PATH_INFO $uri;
                fastcgi_param GIT_PROJECT_ROOT ${cfg.git.repos};
                fastcgi_param GIT_HTTP_EXPORT_ALL "";
                fastcgi_read_timeout 500s;
                fastcgi_max_temp_file_size 512m;
                include ${pkgs.nginx}/conf/fastcgi_params;
                gzip off;
              '';
            };
          }
          cfg.nginx.virtualHost
        ]);
      };
    })
  ]);
}
