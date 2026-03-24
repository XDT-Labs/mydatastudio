import os
import logging
from datetime import timedelta
from flask import Flask, abort, jsonify, redirect
from google.cloud import storage
from google.api_core.exceptions import NotFound

# Set up logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Hardcoded map of URL-friendly keys to full service names
# We use keys here to allow service names containing '/' to be mapped to clean URL paths.
AVAILABLE_SERVICES_MAP = {
    'google-gemma-3-4b-it': 'google_gemma-3-4b-it-Q4_K_M.gguf'
}
# The list for the /services endpoint is derived from the map values (the full service names)
AVAILABLE_SERVICES = list(AVAILABLE_SERVICES_MAP.keys())

# Initialize Flask app
app = Flask(__name__)

# Configuration loaded from environment variables
try:
    # BUCKET_NAME: e.g., 'my-data-bucket'
    BUCKET_NAME = os.environ['GCS_BUCKET']
    # FOLDER_PREFIX: e.g., 'reports/daily/' (must include trailing slash if a folder is specified)
    FOLDER_PREFIX = os.environ.get('GCS_FOLDER_PREFIX', '')
except KeyError:
    logger.error("GCS_BUCKET environment variable is not set.")
    # Exit if critical variable is missing, preventing deployment failure
    raise Exception("Configuration Error: GCS_BUCKET not set.")

# Initialize the Google Cloud Storage client
# When running locally, this will use Application Default Credentials (ADC).
# On Cloud Run, it automatically uses the service's identity.
storage_client = storage.Client()

# Signed URL expiration configuration (default 900s = 15 minutes)
SIGNED_URL_EXPIRATION = int(os.environ.get('SIGNED_URL_EXPIRATION_SECONDS', 900))
logger.info(f'Configured to always use signed URLs for downloads (expiration={SIGNED_URL_EXPIRATION}s)')


@app.route('/download/<service_key>', methods=['GET'])
def download_file(service_key):
    """
    Constructs the full GCS path, incorporating the service_key as a sub-folder,
    and streams the file content to the client.
    """
    # 0. Validate the service key against the map
    if service_key not in AVAILABLE_SERVICES_MAP:
        logger.warning(f"Invalid service key requested: {service_key}")
        # List the valid keys for the user in the error message
        valid_keys = ', '.join(AVAILABLE_SERVICES_MAP.keys())
        abort(400, description=f"Invalid service key. Must be one of: {valid_keys}")

    # Retrieve the full service name for logging purposes
    full_service_name = AVAILABLE_SERVICES_MAP[service_key]

    # 1. Construct the full blob name (path inside the bucket)
    # This creates a path like: FOLDER_PREFIX + full_service_name
    blob_name = FOLDER_PREFIX +full_service_name

    logger.info(f"Attempting to retrieve file for service '{full_service_name}': gs://{BUCKET_NAME}/{blob_name}")

    # 2. Get the bucket and blob
    bucket = storage_client.bucket(BUCKET_NAME)
    blob = bucket.blob(blob_name)

    try:
        # Check existence explicitly to return a 404 without attempting a download
        if not blob.exists():
            logger.warning(f"File Not Found (checked existence): gs://{BUCKET_NAME}/{blob_name}")
            abort(404, description=f"File not found at GCS path: {blob_name}")

        # 3. Stream the file content from GCS without loading it completely into RAM.
        # First, load blob metadata (size, content_type) to set headers.
        try:
            blob.reload()
        except NotFound:
            logger.warning(f"File Not Found (metadata reload): gs://{BUCKET_NAME}/{blob_name}")
            abort(404, description=f"File not found at GCS path: {blob_name}")

        mimetype = blob.content_type or 'application/octet-stream'
        total_size = getattr(blob, 'size', None)

        logger.info(f"Preparing signed URL for file. Size: {total_size} bytes, MimeType: {mimetype}")

        # Always generate a V4 signed URL and redirect the client so downloads come directly from GCS.
        try:
            # This requires the service account to have the "iam.serviceAccountTokenCreator" role.
            from google.auth import compute_engine, impersonated_credentials
            from google.auth.transport import requests as auth_requests
            from google.oauth2 import service_account, credentials as oauth2_credentials
            from google.cloud.storage import blob as storage_blob

            signed_url_kwargs = {
                'version': 'v4',
                'expiration': timedelta(seconds=SIGNED_URL_EXPIRATION),
                'method': 'GET',
                'response_disposition': f'attachment; filename="{full_service_name}"'
            }

            # Check if credentials have a signer (private key) or need IAM-based signing
            creds = storage_client._credentials

            # Service account credentials with private key (local JSON key file)
            if isinstance(creds, service_account.Credentials):
                logger.info("Using service account credentials with private key for signing")
                signed_url = blob.generate_signed_url(**signed_url_kwargs)

            # Compute Engine credentials (Cloud Run, GCE, etc.) - need IAM signing
            elif isinstance(creds, compute_engine.Credentials):
                import google.auth.iam
                import google.auth.transport.requests
                from google.auth import credentials as auth_credentials, default

                service_account_email = creds.service_account_email
                logger.info(f"Using IAM-based signing with compute engine service account: {service_account_email}")

                # Get fresh credentials with explicit scopes for IAM API
                # Cloud Run metadata server provides tokens with limited scopes by default
                # We need to get new credentials with the IAM scope
                try:
                    fresh_creds, project_id = default(scopes=[
                        'https://www.googleapis.com/auth/cloud-platform',
                        'https://www.googleapis.com/auth/iam'
                    ])
                    logger.info(f"Obtained fresh credentials with IAM scopes")
                except Exception as e:
                    logger.warning(f"Could not get scoped credentials: {e}. Using original credentials.")
                    fresh_creds = creds

                # Create a custom signing credentials class that wraps IAM signer
                class IAMSigningCredentials(auth_credentials.Signing):
                    """Wrapper credentials that use IAM signBlob API for signing."""

                    def __init__(self, credentials, service_account_email):
                        self._credentials = credentials
                        self._service_account_email = service_account_email
                        # Ensure credentials are refreshed before creating signer
                        if not credentials.valid:
                            request = google.auth.transport.requests.Request()
                            credentials.refresh(request)
                        self._signer = google.auth.iam.Signer(
                            request=google.auth.transport.requests.Request(),
                            credentials=credentials,
                            service_account_email=service_account_email
                        )

                    def sign_bytes(self, message):
                        """Sign bytes using IAM signBlob API."""
                        return self._signer.sign(message)

                    @property
                    def service_account_email(self):
                        return self._service_account_email

                    @property
                    def signer(self):
                        return self._signer

                    @property
                    def signer_email(self):
                        return self._service_account_email

                    # Required by credentials interface
                    def refresh(self, request):
                        self._credentials.refresh(request)

                    @property
                    def token(self):
                        return self._credentials.token

                    @property
                    def expiry(self):
                        return self._credentials.expiry

                    @property
                    def expired(self):
                        return self._credentials.expired

                    @property
                    def valid(self):
                        return self._credentials.valid

                # Create the wrapped credentials with fresh scoped credentials
                signing_credentials = IAMSigningCredentials(fresh_creds, service_account_email)

                # Use the wrapped credentials for generating the signed URL
                signed_url = blob.generate_signed_url(
                    **signed_url_kwargs,
                    credentials=signing_credentials
                )

            # User credentials from gcloud auth (no private key, no service account)
            # Use the same IAM signing approach as Cloud Run
            elif isinstance(creds, oauth2_credentials.Credentials):
                import google.auth.iam
                import google.auth.transport.requests
                from google.auth import credentials as auth_credentials, default

                logger.info("User credentials detected (gcloud auth application-default login)")

                # Get fresh credentials with explicit scopes for IAM API
                # This allows user credentials to call IAM API on behalf of a service account
                try:
                    fresh_creds, project_id = default(scopes=[
                        'https://www.googleapis.com/auth/cloud-platform',
                        'https://www.googleapis.com/auth/iam'
                    ])

                    # For user credentials, we need to determine which service account to use
                    # Try to get it from environment variable or use the default compute service account
                    service_account_email = os.environ.get('SIGNING_SERVICE_ACCOUNT')
                    if not service_account_email:
                        # Try to get project ID and construct default service account
                        try:
                            from google.cloud import storage as gcs
                            project = project_id or storage_client.project
                            # Get project number for default compute service account
                            from google.cloud import resourcemanager_v3
                            client = resourcemanager_v3.ProjectsClient()
                            project_obj = client.get_project(name=f"projects/{project}")
                            project_number = project_obj.name.split('/')[-1]
                            service_account_email = f"{project_number}-compute@developer.gserviceaccount.com"
                            logger.info(f"Using default compute service account: {service_account_email}")
                        except Exception as e:
                            logger.error(f"Could not determine service account: {e}")
                            abort(500, description="Cannot generate signed URLs with user credentials. "
                                                 "Please set SIGNING_SERVICE_ACCOUNT environment variable or use a service account key file.")

                    logger.info(f"Obtained fresh credentials with IAM scopes, using service account: {service_account_email}")

                    # Create IAM signing credentials wrapper
                    class IAMSigningCredentials(auth_credentials.Signing):
                        """Wrapper credentials that use IAM signBlob API for signing."""

                        def __init__(self, credentials, service_account_email):
                            self._credentials = credentials
                            self._service_account_email = service_account_email
                            if not credentials.valid:
                                request = google.auth.transport.requests.Request()
                                credentials.refresh(request)
                            self._signer = google.auth.iam.Signer(
                                request=google.auth.transport.requests.Request(),
                                credentials=credentials,
                                service_account_email=service_account_email
                            )

                        def sign_bytes(self, message):
                            return self._signer.sign(message)

                        @property
                        def service_account_email(self):
                            return self._service_account_email

                        @property
                        def signer(self):
                            return self._signer

                        @property
                        def signer_email(self):
                            return self._service_account_email

                        def refresh(self, request):
                            self._credentials.refresh(request)

                        @property
                        def token(self):
                            return self._credentials.token

                        @property
                        def expiry(self):
                            return self._credentials.expiry

                        @property
                        def expired(self):
                            return self._credentials.expired

                        @property
                        def valid(self):
                            return self._credentials.valid

                    signing_credentials = IAMSigningCredentials(fresh_creds, service_account_email)
                    signed_url = blob.generate_signed_url(
                        **signed_url_kwargs,
                        credentials=signing_credentials
                    )

                except Exception as e:
                    logger.error(f"Failed to use IAM signing with user credentials: {e}")
                    logger.warning("For local development with gcloud auth, you need:")
                    logger.warning("1. Set SIGNING_SERVICE_ACCOUNT env var, OR")
                    logger.warning("2. Use a service account key: export GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json")
                    abort(500, description=f"Cannot generate signed URLs with user credentials: {e}")

            # Impersonated credentials - have service account email
            elif isinstance(creds, impersonated_credentials.Credentials):
                service_account_email = creds.service_account_email
                logger.info(f"Using IAM-based signing with impersonated service account: {service_account_email}")
                signed_url = blob.generate_signed_url(
                    **signed_url_kwargs,
                    credentials=creds,
                    service_account_email=service_account_email
                )

            # Other credential types with service account email
            elif hasattr(creds, 'service_account_email'):
                service_account_email = creds.service_account_email
                logger.info(f"Using IAM-based signing with service account: {service_account_email}")
                signed_url = blob.generate_signed_url(
                    **signed_url_kwargs,
                    credentials=creds,
                    service_account_email=service_account_email
                )

            # Fallback: try direct signing (may fail if no private key)
            else:
                logger.warning(f"Unknown credential type: {type(creds)}. Attempting direct signing (may fail)")
                signed_url = blob.generate_signed_url(**signed_url_kwargs)

            logger.info(f"Redirecting client to signed URL for gs://{BUCKET_NAME}/{blob_name}")
            return redirect(signed_url, code=302)
        except Exception as e:
            logger.exception(f"Failed to generate signed URL for gs://{BUCKET_NAME}/{blob_name}: {e}")
            abort(500, description="Failed to generate signed URL for download.")

    except NotFound:
        logger.warning(f"File Not Found: gs://{BUCKET_NAME}/{blob_name}")
        abort(404, description=f"File not found at GCS path: {blob_name}")

    except Exception as e:
        logger.exception(f"An unexpected error occurred during file download: {e}")
        abort(500, description="Internal Server Error during file retrieval.")

@app.route('/services', methods=['GET'])
def list_available_services():
    """
    Returns a JSON list of available LLM services/models (the full names).
    """
    logger.info("Request received for available services list.")
    # Returns the list inside a 'services' key in the JSON object
    return jsonify(services=AVAILABLE_SERVICES), 200

@app.route('/', methods=['GET'])
def health_check():
    """Simple health check endpoint."""
    return "GCS Downloader Service is running.", 200

# Gunicorn / Flask entry point
if __name__ == '__main__':
    # Cloud Run will set the PORT environment variable
    port = int(os.environ.get('PORT', 8080))
    app.run(host='0.0.0.0', port=port, debug=True)