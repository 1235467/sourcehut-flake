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
    optionalString
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
      ++ optional cfg.postgresql.enable "postgresql.target";
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
      type = types.submodule { freeformType = settingsFormat.type; };
      default = { };
      description = ''
        Configuration written to {file}`/etc/sr.ht/config.ini`, following the
        layout of the upstream `config.example.ini` files. Keys are used
        verbatim, for example {option}`services.srht.settings.sr.ht.service-key`
        or {option}`services.srht.settings."meta.sr.ht".connection-string`.

        Infrastructure such as the Redis-compatible backend is not managed by
        this module: {option}`services.srht.settings.sr.ht.redis-host` (and
        {option}`services.srht.settings."meta.sr.ht".webhooks`, the Celery
        broker URL for the webhook worker, e.g. `redis://127.0.0.1:6379/1`
        for meta.sr.ht) must be configured to point at your own instance.
      '';
    };

    domain = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        The global domain of the SourceHut instance.
        Defaults to {option}`networking.domain`.
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
        description = "Port the meta.sr.ht API listens on.";
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
        description = "Port the git.sr.ht API listens on.";
      };

      repos = mkOption {
        type = types.path;
        default = "/var/lib/git";
        description = "Path to git repositories on disk.";
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

    nginx = {
      enable = mkEnableOption "local nginx integration";

      virtualHost = mkOption {
        type = types.attrs;
        default = { };
        description = ''
          Virtual host configuration merged with all of SourceHut's virtual
          hosts, for instance to set `enableACME` or TLS certificates.
          TLS via ACME is enabled by default, so
          {option}`security.acme.defaults.email` should be set.
        '';
      };
    };

    postgresql.enable = mkEnableOption "local PostgreSQL integration";
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = domain != null;
          message = ''
            services.srht.domain (or networking.domain) must be set.
          '';
        }
        {
          assertion = (cfg.settings."sr.ht" or { }) ? redis-host;
          message = ''
            services.srht.settings."sr.ht".redis-host must be set to point at
            your Redis-compatible backend (Redis, Valkey, DragonFly, ...).
          '';
        }
        {
          assertion = !cfg.meta.enable || (cfg.settings."meta.sr.ht" or { }) ? webhooks;
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

      services.srht.settings = {
        "sr.ht" = {
          environment = mkDefault "production";
          global-domain = mkDefault domain;
          assets = mkDefault "${assets}";
        };
      }
      // optionalAttrs (domain != null) {
        "meta.sr.ht".origin = mkDefault "https://meta.${domain}";
        "git.sr.ht".origin = mkDefault "https://git.${domain}";
        "git.sr.ht".outgoing-domain = mkDefault "https://git.${domain}";
        "meta.sr.ht::settings".onboarding-redirect = mkDefault "https://meta.${domain}";
      };

      environment.etc."sr.ht/config.ini".source = settingsFormat.generate "sourcehut-config.ini" cfg.settings;

      environment.systemPackages = [
        sourcehutPkgs.sourcehut-migrate
      ];

      systemd.tmpfiles.rules = [
        "f /var/log/sourcehut-ssh.log 0644 root root -"
      ];
    }

    (mkIf cfg.postgresql.enable {
      services.postgresql.enable = mkDefault true;

      services.postgresql.ensureDatabases =
        optional cfg.meta.enable "meta.sr.ht" ++ optional cfg.git.enable "git.sr.ht";

      services.postgresql.ensureUsers =
        optional cfg.meta.enable {
          name = cfg.meta.user;
          ensureDBOwnership = false;
        }
        ++ optional cfg.git.enable {
          name = cfg.git.user;
          ensureDBOwnership = false;
        };

      # Database names contain dots, so ownership cannot be assigned through
      # ensureDBOwnership and has to be handled explicitly.
      systemd.services.postgresql-setup.postStart =
        optionalString cfg.meta.enable ''
          psql -tAc 'ALTER DATABASE "meta.sr.ht" OWNER TO "${cfg.meta.user}";'
        ''
        + optionalString cfg.git.enable ''
          psql -tAc 'ALTER DATABASE "git.sr.ht" OWNER TO "${cfg.git.user}";'
        '';
    })

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
          "meta.sr.ht" = {
            connection-string = mkDefault "postgresql:///meta.sr.ht?user=${cfg.meta.user}&host=/run/postgresql";
            migrate-on-upgrade = mkDefault "yes";
          };
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
          after = [ "postgresql.target" ];
          requires = [ "postgresql.target" ];

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
          requires = optional cfg.postgresql.enable "postgresql.target";
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
          requires = optional cfg.postgresql.enable "postgresql.target";
          serviceConfig = {
            User = cfg.meta.user;
            Group = cfg.meta.group;
            ExecStart = "${cfg.meta.package}/bin/meta.sr.ht-api -b ${cfg.listenAddress}:${toString cfg.meta.apiPort}";
          };
        };

        systemd.services."meta.sr.ht-webhooks" = mkService "meta" {
          description = "meta.sr.ht webhook delivery service";
          wantedBy = [ "multi-user.target" ];
          requires = optional cfg.postgresql.enable "postgresql.target";
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
          }
          // optionalAttrs cfg.postgresql.enable {
            connection-string = mkDefault "postgresql:///git.sr.ht?user=${cfg.git.user}&host=/run/postgresql";
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
          after = [ "postgresql.target" ];
          requires = [ "postgresql.target" ];

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
          requires = optional cfg.postgresql.enable "postgresql.target";
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
          requires = optional cfg.postgresql.enable "postgresql.target";
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

      (mkIf cfg.nginx.enable {
        services.nginx.recommendedProxySettings = mkDefault true;

        services.fcgiwrap.instances.gitsrht = {
          process.prefork = cfg.git.fcgiwrap.prefork;
          process.user = cfg.git.user;
          process.group = cfg.git.group;
          socket.address = "/run/fcgiwrap-gitsrht.sock";
          socket.user = "nginx";
          socket.group = "nginx";
          socket.mode = "0660";
        };
      })
    ]))

    (mkIf cfg.nginx.enable {
      services.nginx.enable = mkDefault true;

      services.nginx.virtualHosts = optionalAttrs (domain != null) {
        "meta.${domain}" = mkIf cfg.meta.enable (mkMerge [
          {
            forceSSL = mkDefault true;
            enableACME = mkDefault true;
            locations."/" = {
              proxyPass = mkDefault "http://${cfg.listenAddress}:${toString cfg.meta.port}";
            };
            locations."/query" = {
              proxyPass = mkDefault "http://${cfg.listenAddress}:${toString cfg.meta.apiPort}";
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
            };
            locations."/query" = {
              proxyPass = mkDefault "http://${cfg.listenAddress}:${toString cfg.git.apiPort}";
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
