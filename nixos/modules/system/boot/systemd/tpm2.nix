{
  lib,
  config,
  pkgs,
  ...
}:
{
  meta.maintainers = [ lib.maintainers.elvishjerricco ];

  imports = [
    (lib.mkRenamedOptionModule
      [ "boot" "initrd" "systemd" "enableTpm2" ]
      [ "boot" "initrd" "systemd" "tpm2" "enable" ]
    )
  ];

  options = {
    systemd.tpm2.enable = lib.mkEnableOption "systemd TPM2 support" // {
      default = config.systemd.package.withTpm2Units;
      defaultText = "systemd.package.withTpm2Units";
    };

    systemd.tpm2.pcrphases.enable = lib.mkEnableOption "systemd boot phase measurements";

    systemd.pcrlock.enable = lib.mkEnableOption "systemd pcrlock TPM NV index policy management";

    boot.initrd.systemd.tpm2.enable = lib.mkEnableOption "systemd initrd TPM2 support" // {
      default = config.boot.initrd.systemd.package.withTpm2Units;
      defaultText = "boot.initrd.systemd.package.withTpm2Units";
    };

    boot.initrd.systemd.tpm2.pcrphases.enable =
      lib.mkEnableOption "systemd initrd boot phase measurements";

    boot.initrd.systemd.pcrlock.enable = lib.mkEnableOption "systemd initrd pcrlock support";
  };

  # TODO: pcrextend, pcrfs, pcrmachine
  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = config.systemd.pcrlock.enable -> config.systemd.tpm2.enable;
          message = "systemd.pcrlock.enable requires systemd.tpm2.enable.";
        }
        {
          assertion = config.boot.initrd.systemd.pcrlock.enable -> config.boot.initrd.systemd.tpm2.enable;
          message = "boot.initrd.systemd.pcrlock.enable requires boot.initrd.systemd.tpm2.enable.";
        }
      ];
    }

    # Stage 2
    (
      let
        cfg = config.systemd;
      in
      lib.mkIf cfg.tpm2.enable {
        systemd.additionalUpstreamSystemUnits = [
          "tpm2.target"
          "systemd-tpm2-setup-early.service"
          "systemd-tpm2-setup.service"
        ];
      }
    )

    # Stage 2 - pcrlock policy management
    (
      let
        cfg = config.systemd;
      in
      lib.mkIf cfg.pcrlock.enable {
        # The static pcrlock components shipped with systemd predict the
        # boot phase measurements (750-enter-initrd, 800-leave-initrd,
        # 850-sysinit, 900-ready) in PCR 11. Without the pcrphase units
        # actually performing those measurements, make-policy treats the
        # components below the location window as missing from the event
        # log and cannot include PCR 11 in the policy.
        systemd.tpm2.pcrphases.enable = lib.mkDefault true;
        boot.initrd.systemd.tpm2.pcrphases.enable = lib.mkDefault true;

        systemd.additionalUpstreamSystemUnits = [
          "systemd-pcrlock-firmware-code.service"
          "systemd-pcrlock-firmware-config.service"
          "systemd-pcrlock-secureboot-policy.service"
          "systemd-pcrlock-secureboot-authority.service"
          "systemd-pcrlock-machine-id.service"
          "systemd-pcrlock-file-system.service"
          "systemd-pcrlock-make-policy.service"

          # The lock-machine-id and lock-file-system services above predict
          # the PCR 15 measurements these two units perform. make-policy
          # covers PCR 15 by default, so the predictions and the
          # measurements must be enabled together or the policy will expect
          # extends that never happen.
          "systemd-pcrmachine.service"
          "systemd-pcrfs-root.service"
        ];

        # These services capture or measure boot-time state and only make
        # sense at the start of a boot, while the TPM event log still
        # matches the PCRs. Their unit files embed the systemd store path,
        # so restarting them on activation would otherwise happen on every
        # systemd upgrade, where their event log validation can refuse and
        # fail the whole switch.
        systemd.services.systemd-pcrlock-firmware-code = {
          wantedBy = [ "sysinit.target" ];
          restartIfChanged = false;
        };
        systemd.services.systemd-pcrlock-firmware-config = {
          wantedBy = [ "sysinit.target" ];
          restartIfChanged = false;
        };
        systemd.services.systemd-pcrlock-secureboot-policy = {
          wantedBy = [ "sysinit.target" ];
          restartIfChanged = false;
        };
        systemd.services.systemd-pcrlock-secureboot-authority = {
          wantedBy = [ "sysinit.target" ];
          restartIfChanged = false;
        };
        systemd.services.systemd-pcrlock-machine-id = {
          wantedBy = [ "sysinit.target" ];
          restartIfChanged = false;
        };
        systemd.services.systemd-pcrlock-file-system = {
          wantedBy = [ "sysinit.target" ];
          restartIfChanged = false;
        };
        systemd.services.systemd-pcrlock-make-policy = {
          wantedBy = [ "sysinit.target" ];
          restartIfChanged = false;
        };
        systemd.services.systemd-pcrmachine = {
          wantedBy = [ "sysinit.target" ];
          restartIfChanged = false;
        };
        systemd.services.systemd-pcrfs-root = {
          wantedBy = [ "sysinit.target" ];
          restartIfChanged = false;
        };

        environment.etc.systemd-pcrlock-builtin = {
          target = "pcrlock.d";
          source = "${cfg.package}/lib/pcrlock.d";
        };
      }
    )
    (
      let
        cfg = config.systemd;
      in
      lib.mkIf (cfg.tpm2.enable && cfg.tpm2.pcrphases.enable) {
        systemd.additionalUpstreamSystemUnits = [
          "systemd-pcrphase.service"
          "systemd-pcrphase-sysinit.service"
        ];
        systemd.services.systemd-pcrphase.wantedBy = [ "sysinit.target" ];
        systemd.services.systemd-pcrphase-sysinit.wantedBy = [ "sysinit.target" ];
      }
    )

    # Stage 1
    (
      let
        cfg = config.boot.initrd.systemd;
      in
      lib.mkIf (cfg.enable && cfg.tpm2.enable) {
        boot.initrd.systemd.additionalUpstreamUnits = [
          "tpm2.target"
          "systemd-tpm2-setup-early.service"
        ];

        boot.initrd.availableKernelModules = [
          "tpm-tis"
        ]
        ++ lib.optional (
          !(pkgs.stdenv.hostPlatform.isRiscV64 || pkgs.stdenv.hostPlatform.isArmv7)
        ) "tpm-crb";
        boot.initrd.systemd.storePaths = [
          pkgs.tpm2-tss
          "${cfg.package}/lib/systemd/systemd-tpm2-setup"
          "${cfg.package}/lib/systemd/system-generators/systemd-tpm2-generator"
        ];
      }
    )
    (
      let
        cfg = config.boot.initrd.systemd;
      in
      lib.mkIf (cfg.enable && cfg.tpm2.enable && cfg.tpm2.pcrphases.enable) {
        boot.initrd.systemd.additionalUpstreamUnits = [ "systemd-pcrphase-initrd.service" ];
        boot.initrd.systemd.services.systemd-pcrphase-initrd.wantedBy = [ "initrd.target" ];
        boot.initrd.systemd.storePaths = [ "${cfg.package}/lib/systemd/systemd-pcrextend" ];
      }
    )

    # Stage 1 - pcrlock
    (
      let
        cfg = config.boot.initrd.systemd;
      in
      lib.mkIf (cfg.enable && cfg.pcrlock.enable) {
        boot.initrd.systemd.storePaths = [
          "${cfg.package}/lib/systemd/systemd-pcrlock"
        ];
      }
    )
  ];
}
