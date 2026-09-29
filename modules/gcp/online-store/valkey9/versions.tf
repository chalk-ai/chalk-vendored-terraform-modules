/**
 * Copyright 2024 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/*
 * Derived from terraform-google-modules/terraform-google-memorystore (modules/valkey),
 * Apache-2.0. Substantially modified by Chalk: the input surface is reduced to identity and
 * sizing, Chalk's preferred configuration is fixed inside the module rather than exposed, and
 * the module publishes a single connection URI that follows Chalk's online-store contract.
 */

terraform {
  required_version = ">= 1.3"

  required_providers {
    google = {
      source = "hashicorp/google"

      # `server_ca_mode` on google_memorystore_instance first shipped in google v7.24.0 --
      # verified by reading `terraform providers schema` for 7.23.0 (absent) and 7.24.0
      # (present). This module sets that attribute unconditionally and it is create-only, so
      # 7.24.0 is a hard floor, not a preference. See README, "Certificate authority".
      #
      # A floor (`>=`) rather than a pessimistic constraint (`~>`): consumers compose this
      # module with their own google provider, and `~>` would make the module uninstallable
      # alongside a newer one.
      version = ">= 7.24.0"
    }
  }
}
