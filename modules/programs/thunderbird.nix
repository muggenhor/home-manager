{ config, lib, pkgs, ... }:

with lib;

let
  inherit (pkgs.stdenv.hostPlatform) isDarwin;

  cfg = config.programs.thunderbird;

  enabledEmailAccounts = attrValues
    (filterAttrs (_: a: a.thunderbird.enable) config.accounts.email.accounts);

  enabledEmailAccountsWithId =
    map (a: a // { id = builtins.hashString "sha256" a.name; })
    enabledEmailAccounts;

  enabledCalendarAccounts = attrValues (filterAttrs (_: a: a.thunderbird.enable)
    config.accounts.calendar.accounts);

  enabledCalendarAccountsWithId =
    map (a: a // { id = builtins.hashString "sha256" a.name; })
    enabledCalendarAccounts;

  thunderbirdConfigPath =
    if isDarwin then "Library/Thunderbird" else ".thunderbird";

  thunderbirdProfilesPath = if isDarwin then
    "${thunderbirdConfigPath}/Profiles"
  else
    thunderbirdConfigPath;

  # The extensions path shared by all profiles; might not be supported
  # by future Thunderbird versions.
  extensionPath = "extensions/{3550f703-e582-4d05-9a08-453d09bdfdc6}";

  profilesWithId =
    imap0 (i: v: v // { id = toString i; }) (attrValues cfg.profiles);

  profilesIni = foldl recursiveUpdate {
    General = {
      StartWithLastProfile = 1;
      Version = 2;
    };
  } (flip map profilesWithId (profile: {
    "Profile${profile.id}" = {
      Name = profile.name;
      Path = if isDarwin then "Profiles/${profile.name}" else profile.name;
      IsRelative = 1;
      Default = if profile.isDefault then 1 else 0;
    };
  }));

  toThunderbirdIdentity = account: address:
    # For backwards compatibility, the primary address reuses the account ID.
    let
      id = if address == account.address then
        account.id
      else
        builtins.hashString "sha256" address;
    in {
      "mail.identity.id_${id}.fullName" = account.realName;
      "mail.identity.id_${id}.useremail" = address;
      "mail.identity.id_${id}.valid" = true;
      "mail.identity.id_${id}.htmlSigText" =
        if account.signature.showSignature == "none" then
          ""
        else
          account.signature.text;
    } // optionalAttrs (account.gpg != null) {
      "mail.identity.id_${id}.attachPgpKey" = false;
      "mail.identity.id_${id}.autoEncryptDrafts" = true;
      "mail.identity.id_${id}.e2etechpref" = 0;
      "mail.identity.id_${id}.encryptionpolicy" =
        if account.gpg.encryptByDefault then 2 else 0;
      "mail.identity.id_${id}.is_gnupg_key_id" = true;
      "mail.identity.id_${id}.last_entered_external_gnupg_key_id" =
        account.gpg.key;
      "mail.identity.id_${id}.openpgp_key_id" = account.gpg.key;
      "mail.identity.id_${id}.protectSubject" = true;
      "mail.identity.id_${id}.sign_mail" = account.gpg.signByDefault;
    } // account.thunderbird.perIdentitySettings id;

  toThunderbirdAccount = account: profile:
    let
      id = account.id;
      addresses = [ account.address ] ++ account.aliases;
    in {
      "mail.account.account_${id}.identities" = concatStringsSep ","
        ([ "id_${id}" ]
          ++ map (address: "id_${builtins.hashString "sha256" address}")
          account.aliases);
      "mail.account.account_${id}.server" = "server_${id}";
    } // optionalAttrs account.primary {
      "mail.accountmanager.defaultaccount" = "account_${id}";
    } // optionalAttrs (account.imap != null) {
      "mail.server.server_${id}.directory" =
        "${thunderbirdProfilesPath}/${profile.name}/ImapMail/${id}";
      "mail.server.server_${id}.directory-rel" = "[ProfD]ImapMail/${id}";
      "mail.server.server_${id}.hostname" = account.imap.host;
      "mail.server.server_${id}.login_at_startup" = true;
      "mail.server.server_${id}.name" = account.name;
      "mail.server.server_${id}.port" =
        if (account.imap.port != null) then account.imap.port else 143;
      "mail.server.server_${id}.socketType" = if !account.imap.tls.enable then
        0
      else if account.imap.tls.useStartTls then
        2
      else
        3;
      "mail.server.server_${id}.type" = "imap";
      "mail.server.server_${id}.userName" = account.userName;
    } // optionalAttrs (account.smtp != null) {
      "mail.identity.id_${id}.smtpServer" = "smtp_${id}";
      "mail.smtpserver.smtp_${id}.authMethod" = 3;
      "mail.smtpserver.smtp_${id}.hostname" = account.smtp.host;
      "mail.smtpserver.smtp_${id}.port" =
        if (account.smtp.port != null) then account.smtp.port else 587;
      "mail.smtpserver.smtp_${id}.try_ssl" = if !account.smtp.tls.enable then
        0
      else if account.smtp.tls.useStartTls then
        2
      else
        3;
      "mail.smtpserver.smtp_${id}.username" = account.userName;
    } // optionalAttrs (account.smtp != null && account.primary) {
      "mail.smtp.defaultserver" = "smtp_${id}";
    } // builtins.foldl' (a: b: a // b) { }
    (builtins.map (address: toThunderbirdIdentity account address) addresses)
    // account.thunderbird.settings id;

  toThunderbirdCalendar = calendar:
    let inherit (calendar) id;
    in {
      "calendar.registry.calendar_${id}.name" = calendar.name;
      "calendar.registry.calendar_${id}.calendar-main-in-composite" = true;
      "calendar.registry.calendar_${id}.cache.enabled" = true;
    } // optionalAttrs (calendar.remote == null) {
      "calendar.registry.calendar_${id}.type" = "storage";
      "calendar.registry.calendar_${id}.uri" = "moz-storage-calendar://";
    } // optionalAttrs (calendar.remote != null) {
      "calendar.registry.calendar_${id}.type" =
        # TODO: assert if remote.type is google_calendar
        if (calendar.remote.type == "http") then
          "ics"
        else
          calendar.remote.type;
      "calendar.registry.calendar_${id}.uri" = calendar.remote.url;
      "calendar.registry.calendar_${id}.username" = calendar.remote.userName;
    } // optionalAttrs calendar.primary {
      "calendar.registry.calendar_${id}.calendar-main-default" = true;
    } // optionalAttrs calendar.thunderbird.readOnly {
      "calendar.registry.calendar_${id}.readOnly" = true;
    } // optionalAttrs (calendar.thunderbird.color != "") {
      "calendar.registry.calendar_${id}.color" = calendar.thunderbird.color;
    };

  mkUserJs = prefs: extraPrefs: ''
    // Generated by Home Manager.

    ${concatStrings (mapAttrsToList (name: value: ''
      user_pref("${name}", ${builtins.toJSON value});
    '') prefs)}
    ${extraPrefs}
  '';
in {
  meta.maintainers = with hm.maintainers; [ d-dervishi jkarlson ];

  options = {
    programs.thunderbird = {
      enable = mkEnableOption "Thunderbird";

      package = mkOption {
        type = types.package;
        default = pkgs.thunderbird;
        defaultText = literalExpression "pkgs.thunderbird";
        example = literalExpression "pkgs.thunderbird-91";
        description = "The Thunderbird package to use.";
      };

      profiles = mkOption {
        type = with types;
          attrsOf (submodule ({ config, name, ... }: {
            options = {
              name = mkOption {
                type = types.str;
                default = name;
                readOnly = true;
                description = "This profile's name.";
              };

              isDefault = mkOption {
                type = types.bool;
                default = false;
                example = true;
                description = ''
                  Whether this is a default profile. There must be exactly one
                  default profile.
                '';
              };

              settings = mkOption {
                type = with types; attrsOf (oneOf [ bool int str ]);
                default = { };
                example = literalExpression ''
                  {
                    "mail.spellcheck.inline" = false;
                  }
                '';
                description = ''
                  Preferences to add to this profile's
                  {file}`user.js`.
                '';
              };

              withExternalGnupg = mkOption {
                type = types.bool;
                default = false;
                example = true;
                description = "Allow using external GPG keys with GPGME.";
              };

              userChrome = mkOption {
                type = types.lines;
                default = "";
                description = "Custom Thunderbird user chrome CSS.";
                example = ''
                  /* Hide tab bar in Thunderbird */
                  #tabs-toolbar {
                    visibility: collapse !important;
                  }
                '';
              };

              userContent = mkOption {
                type = types.lines;
                default = "";
                description = "Custom Thunderbird user content CSS.";
                example = ''
                  /* Hide scrollbar on Thunderbird pages */
                  *{scrollbar-width:none !important}
                '';
              };

              extensions = mkOption {
                type = types.listOf types.package;
                default = [ ];
                example = literalExpression ''
                  with pkgs.nur.repos.muggenhor.thunderbird-addons; [
                    cardbook
                  ]
                '';
                description = ''
                  List of Thunderbird add-on packages to install for this profile.
                  Some pre-packaged add-ons are accessible from the
                  [Nix User Repository](https://github.com/nix-community/NUR).
                  Once you have NUR installed run

                  ```console
                  $ nix-env -f '<nixpkgs>' -qaP -A nur.repos.muggenhor.thunderbird-addons
                  ```

                  to list the available Thunderbird add-ons.

                  Note that it is necessary to manually enable these extensions
                  inside Thunderbird after the first installation.

                  To automatically enable extensions add
                  `"extensions.autoDisableScopes" = 0;`
                  to
                  [{option}`programs.thunderbird.profiles.<profile>.settings`](#opt-programs.thunderbird.profiles._name_.settings)
                '';
              };

              extraConfig = mkOption {
                type = types.lines;
                default = "";
                description = ''
                  Extra preferences to add to {file}`user.js`.
                '';
              };
            };
          }));
        description = "Attribute set of Thunderbird profiles.";
      };

      settings = mkOption {
        type = with types; attrsOf (oneOf [ bool int str ]);
        default = { };
        example = literalExpression ''
          {
            "general.useragent.override" = "";
            "privacy.donottrackheader.enabled" = true;
          }
        '';
        description = ''
          Attribute set of Thunderbird preferences to be added to
          all profiles.
        '';
      };

      darwinSetupWarning = mkOption {
        type = types.bool;
        default = true;
        example = false;
        visible = isDarwin;
        readOnly = !isDarwin;
        description = ''
          Warn to set environment variables before using this module. Only
          relevant on Darwin.
        '';
      };
    };

    accounts.email.accounts = mkOption {
      type = with types;
        attrsOf (submodule {
          options.thunderbird = {
            enable =
              mkEnableOption "the Thunderbird mail client for this account";

            profiles = mkOption {
              type = with types; listOf str;
              default = [ ];
              example = literalExpression ''
                [ "profile1" "profile2" ]
              '';
              description = ''
                List of Thunderbird profiles for which this account should be
                enabled. If this list is empty (the default), this account will
                be enabled for all declared profiles.
              '';
            };

            settings = mkOption {
              type = with types; functionTo (attrsOf (oneOf [ bool int str ]));
              default = _: { };
              defaultText = literalExpression "_: { }";
              example = literalExpression ''
                id: {
                  "mail.server.server_''${id}.check_new_mail" = false;
                };
              '';
              description = ''
                Extra settings to add to this Thunderbird account configuration.
                The {var}`id` given as argument is an automatically
                generated account identifier.
              '';
            };

            perIdentitySettings = mkOption {
              type = with types; functionTo (attrsOf (oneOf [ bool int str ]));
              default = _: { };
              defaultText = literalExpression "_: { }";
              example = literalExpression ''
                id: {
                  "mail.identity.id_''${id}.protectSubject" = false;
                  "mail.identity.id_''${id}.autoEncryptDrafts" = false;
                };
              '';
              description = ''
                Extra settings to add to each identity of this Thunderbird
                account configuration. The {var}`id` given as
                argument is an automatically generated identifier.
              '';
            };
          };
        });
    };
    accounts.calendar.accounts = mkOption {
      type = with types;
        attrsOf (submodule {
          options.thunderbird = {
            enable =
              mkEnableOption "the Thunderbird mail client for this account";

            profiles = mkOption {
              type = with types; listOf str;
              default = [ ];
              example = literalExpression ''
                [ "profile1" "profile2" ]
              '';
              description = ''
                List of Thunderbird profiles for which this account should be
                enabled. If this list is empty (the default), this account will
                be enabled for all declared profiles.
              '';
            };

            readOnly = mkOption {
              type = bool;
              default = false;
              description = "Mark calendar as read only";
            };

            color = mkOption {
              type = str;
              default = "";
              example = "#dc8add";
              description = "Display color of the calendar in hex";
            };
          };
        });
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      (let defaults = catAttrs "name" (filter (a: a.isDefault) profilesWithId);
      in {
        assertion = cfg.profiles == { } || length defaults == 1;
        message = "Must have exactly one default Thunderbird profile but found "
          + toString (length defaults) + optionalString (length defaults > 1)
          (", namely " + concatStringsSep "," defaults);
      })

      (let
        profiles = catAttrs "name" profilesWithId;
        selectedProfiles = concatMap (a: a.thunderbird.profiles)
          (enabledEmailAccounts ++ enabledCalendarAccounts);
      in {
        assertion = (intersectLists profiles selectedProfiles)
          == selectedProfiles;
        message = "Cannot enable an account for a non-declared profile. "
          + "The declared profiles are " + (concatStringsSep "," profiles)
          + ", but the used profiles are "
          + (concatStringsSep "," selectedProfiles);
      })

      (let
        foundCalendars =
          filter (a: a.remote != null && a.remote.type == "google_calendar")
          enabledCalendarAccounts;
      in {
        assertion = length foundCalendars == 0;
        message = ''
          'accounts.calendar.accounts.<name>.remote.type = "google_calendar";' is not supported by Thunderbird, ''
          + "but declared for these calendars: "
          + (concatStringsSep ", " (catAttrs "name" foundCalendars));
      })
    ];

    warnings = optional (isDarwin && cfg.darwinSetupWarning) ''
      Thunderbird packages are not yet supported on Darwin. You can still use
      this module to manage your accounts and profiles by setting
      'programs.thunderbird.package' to a dummy value, for example using
      'pkgs.runCommand'.

      Note that this module requires you to set the following environment
      variables when using an installation of Thunderbird that is not provided
      by Nix:

          export MOZ_LEGACY_PROFILES=1
          export MOZ_ALLOW_DOWNGRADE=1
    '';

    home.packages = [ cfg.package ]
      ++ optional (any (p: p.withExternalGnupg) (attrValues cfg.profiles))
      pkgs.gpgme;

    home.file = mkMerge ([{
      "${thunderbirdConfigPath}/profiles.ini" =
        mkIf (cfg.profiles != { }) { text = generators.toINI { } profilesIni; };
    }] ++ flip mapAttrsToList cfg.profiles (name: profile: {
      "${thunderbirdProfilesPath}/${name}/chrome/userChrome.css" =
        mkIf (profile.userChrome != "") { text = profile.userChrome; };

      "${thunderbirdProfilesPath}/${name}/chrome/userContent.css" =
        mkIf (profile.userContent != "") { text = profile.userContent; };

      "${thunderbirdProfilesPath}/${name}/user.js" = let
        f = filter (a:
          a.thunderbird.profiles == [ ]
          || any (p: p == name) a.thunderbird.profiles);

        accounts = f enabledEmailAccountsWithId;
        calendars = f enabledCalendarAccountsWithId;

        smtp = filter (a: a.smtp != null) accounts;
      in {
        text = mkUserJs (builtins.foldl' (a: b: a // b) { } ([
          cfg.settings

          (optionalAttrs (length accounts != 0) {
            "mail.accountmanager.accounts" =
              concatStringsSep "," (map (a: "account_${a.id}") accounts);
          })

          (optionalAttrs (length smtp != 0) {
            "mail.smtpservers" =
              concatStringsSep "," (map (a: "smtp_${a.id}") smtp);
          })

          { "mail.openpgp.allow_external_gnupg" = profile.withExternalGnupg; }

          profile.settings
        ] ++ (map (a: toThunderbirdAccount a profile) accounts)
          ++ (map toThunderbirdCalendar calendars))) profile.extraConfig;
      };

      "${thunderbirdProfilesPath}/${name}/extensions" =
        mkIf (profile.extensions != [ ]) {
          source = let
            extensionsEnvPkg = pkgs.buildEnv {
              name = "hm-thunderbird-extensions";
              paths = profile.extensions;
            };
          in "${extensionsEnvPkg}/share/mozilla/${extensionPath}";
          recursive = true;
          force = true;
        };
    }));
  };
}
