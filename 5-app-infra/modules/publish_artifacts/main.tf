/**
 * Copyright 2021 Google LLC
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
resource "google_project_service_identity" "artifact_registry_agent" {
  provider = google-beta

  project = var.project_id
  service = "artifactregistry.googleapis.com"
}

resource "google_project_service_identity" "storage_agent" {
  provider = google-beta

  project = var.project_id
  service = "storage.googleapis.com"
}

resource "google_kms_crypto_key_iam_member" "artifact-kms-key-binding" {
  crypto_key_id = var.kms_crypto_key
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_project_service_identity.artifact_registry_agent.email}"
}

resource "google_artifact_registry_repository" "repo" {
  provider               = google-beta
  location               = var.region
  repository_id          = local.name_var
  description            = var.description
  format                 = var.format
  cleanup_policy_dry_run = var.cleanup_policy_dry_run
  project                = data.google_project.project.project_id

  #Customer Managed Encryption Keys
  #Control ID: COM-CO-2.3
  #NIST 800-53: SC-12 SC-13
  #CRI Profile: PR.DS-1.1 PR.DS-1.2 PR.DS-2.1 PR.DS-2.2 PR.DS-5.1

  kms_key_name = var.kms_crypto_key

  #Cleanup policy
  #Control ID:  AR-CO-6.1
  #NIST 800-53: SI-12
  #CRI Profile: PR.IP-2.1 PR.IP-2.2 PR.IP-2.3

  dynamic "cleanup_policies" {
    for_each = var.cleanup_policies
    content {
      id     = cleanup_policies.value.id
      action = cleanup_policies.value.action

      dynamic "condition" {
        for_each = cleanup_policies.value.condition != null ? [cleanup_policies.value.condition] : []
        content {
          tag_state             = condition.value[0].tag_state
          tag_prefixes          = condition.value[0].tag_prefixes
          package_name_prefixes = condition.value[0].package_name_prefixes
          older_than            = condition.value[0].older_than
        }
      }

      dynamic "most_recent_versions" {
        for_each = cleanup_policies.value.most_recent_versions != null ? [cleanup_policies.value.most_recent_versions] : []
        content {
          package_name_prefixes = most_recent_versions.value[0].package_name_prefixes
          keep_count            = most_recent_versions.value[0].keep_count
        }
      }
    }
  }
  depends_on = [
    google_kms_crypto_key_iam_member.artifact-kms-key-binding,
  ]
}

resource "google_artifact_registry_repository_iam_member" "project" {
  for_each   = toset(local.trigger_sa_roles)
  project    = var.project_id
  repository = google_artifact_registry_repository.repo.repository_id
  location   = var.region
  role       = each.key
  member     = google_service_account.trigger_sa.member
}

resource "google_service_account" "trigger_sa" {
  account_id   = var.docker_build_sa_id
  display_name = "Docker Build Service Account"
  project      = var.project_id
}

resource "google_service_account_iam_member" "impersonate" {
  service_account_id = google_service_account.trigger_sa.id
  role               = "roles/iam.serviceAccountUser"
  member             = local.current_member
}

resource "random_string" "suffix" {
  length  = 10
  special = false
  upper   = false
}

// Add Service Agent for Storage
resource "google_kms_crypto_key_iam_member" "storage_agent" {
  crypto_key_id = var.kms_crypto_key
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${data.google_project.project.number}@gs-project-accounts.iam.gserviceaccount.com"

  depends_on = [google_project_service_identity.storage_agent]
  #member = "serviceAccount:${google_project_service_identity.storage.email}"
}

resource "google_storage_bucket" "cloud_build_logs" {
  name                        = "artifacts-pipeline-logs-${random_string.suffix.result}"
  storage_class               = "REGIONAL"
  project                     = var.project_id
  location                    = var.region
  uniform_bucket_level_access = true

  encryption {
    default_kms_key_name = var.kms_crypto_key
  }

  depends_on = [google_kms_crypto_key_iam_member.storage_agent]
}

resource "google_sourcerepo_repository_iam_member" "repo_reader" {
  repository = data.google_sourcerepo_repository.artifacts_repo.id
  role       = "roles/source.reader"
  member     = google_service_account.trigger_sa.member
}

resource "google_storage_bucket_iam_member" "storage_admin" {
  bucket = google_storage_bucket.cloud_build_logs.name
  role   = "roles/storage.admin"
  member = google_service_account.trigger_sa.member
}

resource "google_cloudbuild_trigger" "docker_build" {
  name            = "docker-build"
  project         = var.project_id
  location        = var.region
  service_account = google_service_account.trigger_sa.id

  trigger_template {
    branch_name  = "^main$"
    repo_name    = var.name
    invert_regex = false
  }

  build {
    logs_bucket = google_storage_bucket.cloud_build_logs.name
    timeout     = "1800s"
    step {
      id         = "unshallow"
      name       = "gcr.io/cloud-builders/git"
      entrypoint = "/bin/bash"
      args = [
        "-c",
        "git fetch --unshallow"
      ]
    }
    step {
      id         = "select-folder"
      name       = "gcr.io/cloud-builders/git"
      entrypoint = "/bin/bash"
      args = [
        "-c",
        <<-EOT
        changed_files=$(git diff $${COMMIT_SHA}^1 --name-only -r)
        changed_folders=$(echo "$changed_files" | awk -F/ '{print $2}' | sort | uniq )
        for folder in $changed_folders; do
            echo "Found docker folder: $folder"
            echo $folder >> /workspace/docker_build
        done
        EOT
      ]
    }
    step {
      id         = "build-image"
      wait_for   = ["select-folder"]
      name       = "gcr.io/cloud-builders/docker"
      entrypoint = "/bin/bash"
      args = [
        "-c",
        <<-EOT
        build_path="/workspace/docker_build"
        while IFS= read -r line; do
          docker build -t ${var.region}-docker.pkg.dev/$PROJECT_ID/c-publish-artifacts/$line images/$line
        done < "$build_path"
        EOT
      ]
    }

    step {
      id         = "push-image"
      wait_for   = ["select-folder", "build-image"]
      name       = "gcr.io/cloud-builders/docker"
      entrypoint = "/bin/bash"
      args = [
        "-c",
        <<-EOT
        build_path="/workspace/docker_build"
        while IFS= read -r line; do
          docker push ${var.region}-docker.pkg.dev/$PROJECT_ID/c-publish-artifacts/$line
        done < "$build_path"
        EOT
      ]
    }
  }

  depends_on = [google_service_account_iam_member.impersonate]
}
