# This file has been generated by node2nix 1.11.1. Do not edit!

{nodeEnv, fetchurl, fetchgit, nix-gitignore, stdenv, lib, globalBuildInputs ? []}:

let
  sources = {
    "playwright-1.43.0" = {
      name = "playwright";
      packageName = "playwright";
      version = "1.43.0";
      src = fetchurl {
        url = "https://registry.npmjs.org/playwright/-/playwright-1.43.0.tgz";
        sha512 = "SiOKHbVjTSf6wHuGCbqrEyzlm6qvXcv7mENP+OZon1I07brfZLGdfWV0l/efAzVx7TF3Z45ov1gPEkku9q25YQ==";
      };
    };
    "playwright-core-1.43.0" = {
      name = "playwright-core";
      packageName = "playwright-core";
      version = "1.43.0";
      src = fetchurl {
        url = "https://registry.npmjs.org/playwright-core/-/playwright-core-1.43.0.tgz";
        sha512 = "iWFjyBUH97+pUFiyTqSLd8cDMMOS0r2ZYz2qEsPjH8/bX++sbIJT35MSwKnp1r/OQBAqC5XO99xFbJ9XClhf4w==";
      };
    };
  };
in
{
  "@playwright/test-1.43.0" = nodeEnv.buildNodePackage {
    name = "_at_playwright_slash_test";
    packageName = "@playwright/test";
    version = "1.43.0";
    src = fetchurl {
      url = "https://registry.npmjs.org/@playwright/test/-/test-1.43.0.tgz";
      sha512 = "Ebw0+MCqoYflop7wVKj711ccbNlrwTBCtjY5rlbiY9kHL2bCYxq+qltK6uPsVBGGAOb033H2VO0YobcQVxoW7Q==";
    };
    dependencies = [
      sources."playwright-1.43.0"
      sources."playwright-core-1.43.0"
    ];
    buildInputs = globalBuildInputs;
    meta = {
      description = "A high-level API to automate web browsers";
      homepage = "https://playwright.dev";
      license = "Apache-2.0";
    };
    production = true;
    bypassCache = true;
    reconstructLock = true;
  };
}
