const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests whose names do not match any filter",
    ) orelse &.{};

    // What the service modules share. It imports nothing but std.
    const core = b.addModule("core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Credentials for the service modules. It imports core, never a service.
    const auth = b.addModule("auth", .{
        .root_source_file = b.path("src/auth/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core }},
    });

    const mod = b.addModule("pubsub", .{
        .root_source_file = b.path("src/pubsub/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core }},
    });

    // Secrets. It imports core, never a service.
    const secret_manager = b.addModule("secret_manager", .{
        .root_source_file = b.path("src/secret_manager/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core }},
    });

    // Cloud Storage. It imports core, never a service.
    const storage = b.addModule("storage", .{
        .root_source_file = b.path("src/storage/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core }},
    });

    // Cloud Firestore. It imports core, never a service.
    const firestore = b.addModule("firestore", .{
        .root_source_file = b.path("src/firestore/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core }},
    });

    // Cloud Logging, the read side. It imports core, never a service.
    const logging = b.addModule("logging", .{
        .root_source_file = b.path("src/logging/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core }},
    });

    // Cloud Resource Manager, the projects a credential can see. It
    // imports core, never a service.
    const resource_manager = b.addModule("resource_manager", .{
        .root_source_file = b.path("src/resource_manager/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core }},
    });

    // Cloud Error Reporting, the read side: error groups, their counts and
    // events, and a group's status. It imports core, never a service.
    const error_reporting = b.addModule("error_reporting", .{
        .root_source_file = b.path("src/error_reporting/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core }},
    });

    // Cloud Monitoring: a program's own metrics, written and read, and
    // their descriptors. It imports core, never a service.
    const monitoring = b.addModule("monitoring", .{
        .root_source_file = b.path("src/monitoring/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core }},
    });

    // Cloud KMS: keys used and managed. It imports core, never a service.
    const kms = b.addModule("kms", .{
        .root_source_file = b.path("src/kms/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core }},
    });

    // Cloud Scheduler, read only. It imports core, never a service.
    const scheduler = b.addModule("scheduler", .{
        .root_source_file = b.path("src/scheduler/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core }},
    });

    // Cloud Run, read only. It imports core, never a service.
    const cloud_run = b.addModule("run", .{
        .root_source_file = b.path("src/run/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core }},
    });

    // Dataflow, read only. It imports core, never a service.
    const dataflow = b.addModule("dataflow", .{
        .root_source_file = b.path("src/dataflow/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core }},
    });

    // Every test build runs under std's test runner with one fix, which
    // keeps std.debug from swallowing a task's cancel (see the top of
    // tools/test_runner.zig).
    const test_runner: std.Build.Step.Compile.TestRunner = .{ .path = b.path("tools/test_runner.zig"), .mode = .server };

    // Fuzzing needs the LLVM backend. The self-hosted x86_64 backend, the
    // Debug default there, emits no coverage instrumentation, so the fuzzer
    // would run blind.
    const fuzz_runner = b.option(
        bool,
        "fuzz-runner",
        "Build the unit tests for `zig build test --fuzz`: LLVM backend",
    ) orelse false;

    // Unit, property and fuzz-corpus tests, one run per module. No network: a
    // fake transport and a fake clock drive everything.
    // `zig build test -Dfuzz-runner --fuzz` fuzzes the same tests.
    const unit_modules = [_]struct { []const u8, *std.Build.Module }{
        .{ "core", core },
        .{ "auth", auth },
        .{ "pubsub", mod },
        .{ "secret_manager", secret_manager },
        .{ "storage", storage },
        .{ "firestore", firestore },
        .{ "logging", logging },
        .{ "resource_manager", resource_manager },
        .{ "error_reporting", error_reporting },
        .{ "monitoring", monitoring },
        .{ "kms", kms },
        .{ "scheduler", scheduler },
        .{ "run", cloud_run },
        .{ "dataflow", dataflow },
    };
    // The nightly fuzz job runs one module per job, so each gets the whole
    // time budget: `--fuzz=N` fuzzes every property N times, and the
    // properties of all the modules together outgrew one job.
    const only_module = b.option(
        []const u8,
        "module",
        "Run only this module's unit tests: core, auth, pubsub, secret_manager, storage, firestore, logging, resource_manager, error_reporting, monitoring, kms, scheduler, run or dataflow",
    );
    if (only_module) |name| {
        for (unit_modules) |entry| {
            if (std.mem.eql(u8, entry[0], name)) break;
        } else std.process.fatal("-Dmodule={s} names no module; use core, auth, pubsub, secret_manager, storage, firestore, logging, resource_manager, error_reporting, monitoring, kms, scheduler, run or dataflow", .{name});
    }
    const test_step = b.step("test", "Run unit, property and fuzz-corpus tests");
    // The same tests without what `test` compiles beside them, the examples
    // and the suites that need a server: CI's optimized jobs spend their
    // time compiling, and its Debug jobs build those already.
    const unit_step = b.step("test-unit", "Run unit, property and fuzz-corpus tests, compiling nothing else");
    test_step.dependOn(unit_step);
    for (unit_modules) |entry| {
        if (only_module) |name| if (!std.mem.eql(u8, entry[0], name)) continue;
        const unit_tests = b.addTest(.{
            .name = entry[0],
            .root_module = entry[1],
            .filters = test_filters,
            .test_runner = test_runner,
            .use_llvm = if (fuzz_runner) true else null,
        });
        unit_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }

    // Signed URLs held to outside answers: Google's conformance vectors,
    // with real RSA signatures, and cases Google's Python library signed.
    // The files live in tests/testdata, outside the package, so these run
    // beside the storage module's unit tests rather than among them.
    const signing_tests = b.addTest(.{
        .name = "storage-signing",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/storage_signing.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "storage", .module = storage },
                .{ .name = "auth", .module = auth },
                .{ .name = "core", .module = core },
            },
        }),
        .filters = test_filters,
        .test_runner = test_runner,
        .use_llvm = if (fuzz_runner) true else null,
    });
    if (only_module == null or std.mem.eql(u8, only_module.?, "storage")) {
        unit_step.dependOn(&b.addRunArtifact(signing_tests).step);
    }

    // The code the documentation shows, run beside pubsub's unit tests so
    // it cannot drift; tools/check_docs.py holds the docs to this file.
    const docs_tests = b.addTest(.{
        .name = "docs-examples",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/docs_examples.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pubsub", .module = mod },
                .{ .name = "auth", .module = auth },
                .{ .name = "error_reporting", .module = error_reporting },
                .{ .name = "monitoring", .module = monitoring },
                .{ .name = "kms", .module = kms },
                .{ .name = "secret_manager", .module = secret_manager },
                .{ .name = "firestore", .module = firestore },
                .{ .name = "storage", .module = storage },
                .{ .name = "logging", .module = logging },
                .{ .name = "resource_manager", .module = resource_manager },
                .{ .name = "scheduler", .module = scheduler },
                .{ .name = "run", .module = cloud_run },
                .{ .name = "dataflow", .module = dataflow },
                .{ .name = "core", .module = core },
            },
        }),
        .filters = test_filters,
        .test_runner = test_runner,
        .use_llvm = if (fuzz_runner) true else null,
    });
    if (only_module == null or std.mem.eql(u8, only_module.?, "pubsub")) {
        unit_step.dependOn(&b.addRunArtifact(docs_tests).step);
    }

    // Line coverage of the unit tests, measured by kcov, which must be on
    // PATH. Each module's tests run under kcov, and the merged report is
    // installed to zig-out/coverage: index.html, plus coverage.json and
    // cobertura.xml in kcov-merged/.
    const coverage_step = b.step("coverage", "Measure the unit tests' line coverage with kcov");
    const merge = b.addSystemCommand(&.{ "kcov", "--merge" });
    const merged = merge.addOutputDirectoryArg2("coverage", .{});
    for (unit_modules) |entry| {
        const coverage_tests = b.addTest(.{
            .name = entry[0],
            .root_module = entry[1],
            .filters = test_filters,
            .test_runner = test_runner,
            // kcov maps addresses to lines through DWARF, which LLVM emits in full.
            .use_llvm = true,
        });
        const kcov = b.addSystemCommand(&.{"kcov"});
        kcov.addDirectoryArg2(b.path("src"), .{ .prefix = "--include-path=", .make_absolute = true });
        merge.addDirectoryArg2(kcov.addOutputDirectoryArg2(entry[0], .{}), .{});
        kcov.addArtifactArg2(coverage_tests, .{});
        // The tests' progress output is captured: the build shows it only
        // when they fail, which kcov reports by exiting as they did.
        _ = kcov.captureStdErr(.{});
    }
    coverage_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = merged,
        .install_dir = .prefix,
        .install_subdir = "coverage",
    }).step);

    // Integration tests against the emulator (PUBSUB_EMULATOR_HOST) or, when
    // configured, a real project. They skip cleanly when neither is set.
    const integration_tests = b.addTest(.{
        .name = "integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "pubsub", .module = mod }},
        }),
        .filters = test_filters,
        .test_runner = test_runner,
    });
    const run_integration = streamed(b, integration_tests);
    const integration_step = b.step(
        "test-integration",
        "Run integration tests against PUBSUB_EMULATOR_HOST, or Google when configured",
    );
    integration_step.dependOn(&run_integration.step);

    // Cloud Storage against fake-gcs-server (STORAGE_EMULATOR_HOST). The
    // tests skip cleanly when it is not set.
    const storage_integration_tests = b.addTest(.{
        .name = "storage-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/storage_integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "storage", .module = storage },
                .{ .name = "core", .module = core },
            },
        }),
        .filters = test_filters,
        .test_runner = test_runner,
    });
    const run_storage_integration = streamed(b, storage_integration_tests);
    integration_step.dependOn(&run_storage_integration.step);

    // Cloud Firestore against its emulator (FIRESTORE_EMULATOR_HOST). The
    // tests skip cleanly when it is not set.
    const firestore_integration_tests = b.addTest(.{
        .name = "firestore-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/firestore_integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "firestore", .module = firestore },
                .{ .name = "core", .module = core },
            },
        }),
        .filters = test_filters,
        .test_runner = test_runner,
    });
    const run_firestore_integration = streamed(b, firestore_integration_tests);
    integration_step.dependOn(&run_firestore_integration.step);

    // Cloud Storage's notifications end to end: fake-gcs-server publishing
    // to the Pub/Sub emulator. Skips unless both are set.
    const notifications_integration_tests = b.addTest(.{
        .name = "notifications-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/notifications_integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "storage", .module = storage },
                .{ .name = "pubsub", .module = mod },
            },
        }),
        .filters = test_filters,
        .test_runner = test_runner,
    });
    const run_notifications_integration = streamed(b, notifications_integration_tests);
    integration_step.dependOn(&run_notifications_integration.step);

    // auth against Google's token endpoint, when AUTH_TEST_CREDENTIALS names
    // a credentials file. They skip otherwise.
    const auth_integration_tests = b.addTest(.{
        .name = "auth-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/auth_integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "auth", .module = auth },
                .{ .name = "pubsub", .module = mod },
            },
        }),
        .filters = test_filters,
        .test_runner = test_runner,
    });
    const run_auth_integration = streamed(b, auth_integration_tests);
    integration_step.dependOn(&run_auth_integration.step);

    // Against real Google Cloud, with credentials CI does not have, so a
    // step of their own, never part of `test-integration`. Each suite skips
    // without its variables. `zig build test` compiles them, as it does the
    // examples, so they cannot rot between runs.
    const gcp_step = b.step(
        "test-integration-gcp",
        "Run the Secret Manager, Cloud Storage, signed URL, Firestore, Logging, Resource Manager, Error Reporting, Monitoring and KMS tests against Google: GCP_TEST_PROJECT, GCP_TEST_BUCKET, FIRESTORE_TEST_DATABASE, KMS_TEST_KEY_RING",
    );
    // Secret Manager has no emulator, so its tests need GCP_TEST_PROJECT
    // and GCP_TEST_TOKEN.
    const gcp_tests = b.addTest(.{
        .name = "secret-manager-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/secret_manager_integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "secret_manager", .module = secret_manager },
                .{ .name = "pubsub", .module = mod },
            },
        }),
        .filters = test_filters,
        .test_runner = test_runner,
    });
    gcp_step.dependOn(&streamed(b, gcp_tests).step);
    test_step.dependOn(&gcp_tests.step);
    // Cloud Storage against a real bucket, for what fake-gcs-server cannot
    // show: GCP_TEST_BUCKET and GCP_TEST_TOKEN.
    const storage_gcp_tests = b.addTest(.{
        .name = "storage-gcp-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/storage_gcp_integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "storage", .module = storage },
                .{ .name = "core", .module = core },
            },
        }),
        .filters = test_filters,
        .test_runner = test_runner,
    });
    gcp_step.dependOn(&streamed(b, storage_gcp_tests).step);
    test_step.dependOn(&storage_gcp_tests.step);
    // A bucket's Pub/Sub notifications against Google: GCP_TEST_PROJECT,
    // GCP_TEST_BUCKET and GCP_TEST_TOKEN, with topics and their policies.
    const notifications_gcp_tests = b.addTest(.{
        .name = "notifications-gcp-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/notifications_gcp_integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "storage", .module = storage },
                .{ .name = "pubsub", .module = mod },
            },
        }),
        .filters = test_filters,
        .test_runner = test_runner,
    });
    gcp_step.dependOn(&streamed(b, notifications_gcp_tests).step);
    test_step.dependOn(&notifications_gcp_tests.step);
    // Firestore against a real project, in a named database made for the
    // run: GCP_TEST_PROJECT, GCP_TEST_TOKEN and FIRESTORE_TEST_DATABASE.
    const firestore_gcp_tests = b.addTest(.{
        .name = "firestore-gcp-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/firestore_gcp_integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "firestore", .module = firestore },
                .{ .name = "core", .module = core },
            },
        }),
        .filters = test_filters,
        .test_runner = test_runner,
    });
    gcp_step.dependOn(&streamed(b, firestore_gcp_tests).step);
    test_step.dependOn(&firestore_gcp_tests.step);
    // Cloud Logging against a real project: GCP_TEST_PROJECT and
    // GCP_TEST_TOKEN, a token that may write and read logs.
    const logging_gcp_tests = b.addTest(.{
        .name = "logging-gcp-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/logging_gcp_integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "logging", .module = logging },
                .{ .name = "core", .module = core },
            },
        }),
        .filters = test_filters,
        .test_runner = test_runner,
    });
    gcp_step.dependOn(&streamed(b, logging_gcp_tests).step);
    test_step.dependOn(&logging_gcp_tests.step);
    // Resource Manager against a real project, read only: GCP_TEST_PROJECT,
    // a project the token's principal can see, and GCP_TEST_TOKEN.
    const resource_manager_gcp_tests = b.addTest(.{
        .name = "resource-manager-gcp-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/resource_manager_gcp_integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "resource_manager", .module = resource_manager },
                .{ .name = "core", .module = core },
            },
        }),
        .filters = test_filters,
        .test_runner = test_runner,
    });
    gcp_step.dependOn(&streamed(b, resource_manager_gcp_tests).step);
    test_step.dependOn(&resource_manager_gcp_tests.step);
    // Cloud Monitoring against a real project with the API on:
    // GCP_TEST_PROJECT and GCP_TEST_TOKEN, a token that may write and read
    // metrics and create and delete descriptors. Each run writes under its
    // own zigps- prefix and deletes every descriptor there.
    const monitoring_gcp_tests = b.addTest(.{
        .name = "monitoring-gcp-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/monitoring_gcp_integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "monitoring", .module = monitoring },
                .{ .name = "core", .module = core },
                .{ .name = "pubsub", .module = mod },
            },
        }),
        .filters = test_filters,
        .test_runner = test_runner,
    });
    gcp_step.dependOn(&streamed(b, monitoring_gcp_tests).step);
    test_step.dependOn(&monitoring_gcp_tests.step);
    // Cloud Scheduler against a real project with the API on, gated on
    // SCHEDULER_TEST=1 beside the usual two variables: the suite makes,
    // runs, pauses and deletes two zigps- jobs raw, since the client
    // reads only, and holds the fake to production's answers.
    const scheduler_gcp_tests = b.addTest(.{
        .name = "scheduler-gcp-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/scheduler_gcp_integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "scheduler", .module = scheduler },
                .{ .name = "core", .module = core },
            },
        }),
        .filters = test_filters,
        .test_runner = test_runner,
    });
    gcp_step.dependOn(&streamed(b, scheduler_gcp_tests).step);
    test_step.dependOn(&scheduler_gcp_tests.step);
    // Cloud Run against a real project with the API on, gated on
    // RUN_TEST=1 beside the usual two variables: the suite deploys,
    // breaks and deletes a zigps- hello service raw, since the client
    // reads only, and holds the fake to production's answers.
    const run_gcp_tests = b.addTest(.{
        .name = "run-gcp-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/run_gcp_integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "run", .module = cloud_run },
                .{ .name = "core", .module = core },
            },
        }),
        .filters = test_filters,
        .test_runner = test_runner,
    });
    gcp_step.dependOn(&streamed(b, run_gcp_tests).step);
    test_step.dependOn(&run_gcp_tests.step);
    // Dataflow against a real project with the API on, gated on
    // DATAFLOW_TEST=1 beside the usual two variables: the suite
    // launches one zigps- Word_Count template job raw (a cent or two,
    // the spend the spec's answers approved), since the client reads
    // only, and holds the fake to production's answers.
    const dataflow_gcp_tests = b.addTest(.{
        .name = "dataflow-gcp-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/dataflow_gcp_integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "dataflow", .module = dataflow },
                .{ .name = "core", .module = core },
            },
        }),
        .filters = test_filters,
        .test_runner = test_runner,
    });
    gcp_step.dependOn(&streamed(b, dataflow_gcp_tests).step);
    test_step.dependOn(&dataflow_gcp_tests.step);
    // Error Reporting against a real project with the API on:
    // GCP_TEST_PROJECT and GCP_TEST_TOKEN, a token that may report errors
    // and read and update groups. Each run reports a few errors of its own.
    const error_reporting_gcp_tests = b.addTest(.{
        .name = "error-reporting-gcp-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/error_reporting_gcp_integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "error_reporting", .module = error_reporting },
                .{ .name = "core", .module = core },
            },
        }),
        .filters = test_filters,
        .test_runner = test_runner,
    });
    gcp_step.dependOn(&streamed(b, error_reporting_gcp_tests).step);
    test_step.dependOn(&error_reporting_gcp_tests.step);
    // Cloud KMS against a key ring kept for the suite: GCP_TEST_PROJECT,
    // GCP_TEST_TOKEN and KMS_TEST_KEY_RING, on which the token's principal
    // holds roles/cloudkms.admin and roles/cloudkms.cryptoOperator. Keys
    // are destroyed as a run ends and deleted by a later run.
    const kms_gcp_tests = b.addTest(.{
        .name = "kms-gcp-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/kms_gcp_integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "kms", .module = kms },
            },
        }),
        .filters = test_filters,
        .test_runner = test_runner,
    });
    gcp_step.dependOn(&streamed(b, kms_gcp_tests).step);
    test_step.dependOn(&kms_gcp_tests.step);
    // Signed URLs against a real bucket, which is the only place a
    // signature is checked: GCP_TEST_BUCKET, GCP_TEST_TOKEN, and a signer,
    // GCP_TEST_SIGNER_KEY or GCP_TEST_SIGNER_EMAIL.
    const signed_url_gcp_tests = b.addTest(.{
        .name = "signed-url-gcp-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/signed_url_gcp_integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "storage", .module = storage },
                .{ .name = "auth", .module = auth },
                .{ .name = "core", .module = core },
            },
        }),
        .filters = test_filters,
        .test_runner = test_runner,
    });
    gcp_step.dependOn(&streamed(b, signed_url_gcp_tests).step);
    test_step.dependOn(&signed_url_gcp_tests.step);

    // Fault injection: the full stack against the emulator, through a proxy
    // that drops, cuts, delays and rewrites responses. Skips without
    // PUBSUB_EMULATOR_HOST; never runs against production.
    const fault_tests = b.addTest(.{
        .name = "fault-injection",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fault_injection.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pubsub", .module = mod },
                .{ .name = "core", .module = core },
            },
        }),
        .filters = test_filters,
        .test_runner = test_runner,
    });
    const run_fault = streamed(b, fault_tests);
    integration_step.dependOn(&run_fault.step);

    inline for (.{ "publish", "publisher", "worker", "in_memory", "whoami", "secret", "gcs_cp", "gcs_sign", "gcs_notify", "gcs_folders", "quickstart", "iam", "secret_rotation", "firestore", "logs_read", "logs_tail", "projects_list", "error_dashboard", "monitoring", "monitoring_alerts", "monitoring_policies", "pubsub_metrics", "kms", "scheduler_jobs", "scheduler_run", "run_revisions", "dataflow_jobs" }) |name| {
        // whoami, secret, gcs_cp, gcs_sign, gcs_notify, quickstart, iam,
        // secret_rotation, firestore, logs_read, logs_tail, projects_list,
        // error_dashboard, monitoring, monitoring_alerts,
        // monitoring_policies, pubsub_metrics,
        // kms, scheduler_jobs, scheduler_run, run_revisions and
        // dataflow_jobs pick their own credentials.
        const imports: []const std.Build.Module.Import = if (std.mem.eql(u8, name, "whoami"))
            &.{ .{ .name = "pubsub", .module = mod }, .{ .name = "auth", .module = auth } }
        else if (std.mem.eql(u8, name, "secret"))
            &.{ .{ .name = "secret_manager", .module = secret_manager }, .{ .name = "auth", .module = auth } }
        else if (std.mem.eql(u8, name, "gcs_cp") or std.mem.eql(u8, name, "gcs_sign") or std.mem.eql(u8, name, "gcs_folders"))
            &.{ .{ .name = "storage", .module = storage }, .{ .name = "auth", .module = auth } }
        else if (std.mem.eql(u8, name, "iam"))
            &.{ .{ .name = "storage", .module = storage }, .{ .name = "pubsub", .module = mod }, .{ .name = "secret_manager", .module = secret_manager }, .{ .name = "auth", .module = auth } }
        else if (std.mem.eql(u8, name, "secret_rotation"))
            &.{ .{ .name = "secret_manager", .module = secret_manager }, .{ .name = "pubsub", .module = mod }, .{ .name = "auth", .module = auth } }
        else if (std.mem.eql(u8, name, "firestore"))
            &.{ .{ .name = "firestore", .module = firestore }, .{ .name = "auth", .module = auth } }
        else if (std.mem.eql(u8, name, "logs_read") or std.mem.eql(u8, name, "logs_tail"))
            &.{ .{ .name = "logging", .module = logging }, .{ .name = "auth", .module = auth } }
        else if (std.mem.eql(u8, name, "projects_list"))
            &.{ .{ .name = "resource_manager", .module = resource_manager }, .{ .name = "auth", .module = auth } }
        else if (std.mem.eql(u8, name, "error_dashboard"))
            &.{ .{ .name = "error_reporting", .module = error_reporting }, .{ .name = "auth", .module = auth } }
        else if (std.mem.eql(u8, name, "monitoring") or std.mem.eql(u8, name, "monitoring_alerts") or std.mem.eql(u8, name, "monitoring_policies"))
            &.{ .{ .name = "monitoring", .module = monitoring }, .{ .name = "auth", .module = auth } }
        else if (std.mem.eql(u8, name, "pubsub_metrics"))
            &.{ .{ .name = "pubsub", .module = mod }, .{ .name = "monitoring", .module = monitoring }, .{ .name = "auth", .module = auth } }
        else if (std.mem.eql(u8, name, "kms"))
            &.{ .{ .name = "kms", .module = kms }, .{ .name = "auth", .module = auth } }
        else if (std.mem.eql(u8, name, "scheduler_jobs") or std.mem.eql(u8, name, "scheduler_run"))
            &.{ .{ .name = "scheduler", .module = scheduler }, .{ .name = "auth", .module = auth } }
        else if (std.mem.eql(u8, name, "run_revisions"))
            &.{ .{ .name = "run", .module = cloud_run }, .{ .name = "auth", .module = auth } }
        else if (std.mem.eql(u8, name, "dataflow_jobs"))
            &.{ .{ .name = "dataflow", .module = dataflow }, .{ .name = "auth", .module = auth } }
        else if (std.mem.eql(u8, name, "gcs_notify") or std.mem.eql(u8, name, "quickstart"))
            &.{ .{ .name = "storage", .module = storage }, .{ .name = "pubsub", .module = mod }, .{ .name = "auth", .module = auth } }
        else
            &.{.{ .name = "pubsub", .module = mod }};
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/" ++ name ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = imports,
            }),
        });
        const run = b.addRunArtifact(exe);
        run.addPassthruArgs();
        const step = b.step("example-" ++ name, "Run examples/" ++ name ++ ".zig");
        step.dependOn(&run.step);
        // Compile the examples with the unit tests so they never rot.
        test_step.dependOn(&exe.step);
    }

    // How fast this build computes a CRC-32C, always in ReleaseFast: the
    // numbers are about the code the CPU runs, not a debug build's.
    const bench_crc32c = b.addExecutable(.{
        .name = "bench-crc32c",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bench_crc32c.zig"),
            .target = target,
            .optimize = .fast,
            .imports = &.{.{ .name = "core", .module = b.createModule(.{
                .root_source_file = b.path("src/core/root.zig"),
                .target = target,
                .optimize = .fast,
            }) }},
        }),
    });
    b.step("bench-crc32c", "Measure CRC-32C throughput, in ReleaseFast").dependOn(&b.addRunArtifact(bench_crc32c).step);
    test_step.dependOn(&bench_crc32c.step);

    const fmt = b.addFmt(.{
        .paths = b.pathList(&.{ "build.zig", "build.zig.zon", "src", "tests", "examples", "tools" }),
        .check = true,
    });
    b.step("fmt", "Check formatting (zig fmt --check)").dependOn(&fmt.step);
}

/// Runs an integration suite as a plain program instead of through the build
/// runner's test protocol, which prints nothing until the suite ends. Run
/// this way, the test runner prints each test's name as the test starts, so
/// a suite that hangs leaves a log that says which test it was. Output goes
/// straight through, which also makes the step run alone: the suites take
/// turns with the emulator instead of loading it all at once. And such a
/// step always runs, since its result depends on a server, never the cache.
fn streamed(b: *std.Build, tests: *std.Build.Step.Compile) *std.Build.Step.Run {
    const run = std.Build.Step.Run.create(b, b.fmt("run {s}", .{tests.name}));
    run.addArtifactArg2(tests, .{});
    run.stdio = .inherit;
    return run;
}
