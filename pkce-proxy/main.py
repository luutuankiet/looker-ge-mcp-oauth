"""
PKCE Proxy for Looker OAuth with Gemini Enterprise
===================================================

This Cloud Function bridges the gap between:
- Gemini Enterprise's serverSideOauth2 (requires clientSecret, uses PKCE internally)
- Looker's CORS OAuth (public client, requires PKCE)

Flow:
1. /auth    - Gemini redirects user here. We generate PKCE, redirect to Looker.
2. /callback - Looker redirects here with auth code. We wrap code+verifier, redirect to Gemini.
3. /token   - Gemini calls here to exchange code. We unwrap and call Looker with PKCE.

No external storage needed - code_verifier is encoded in the authorization code itself.
"""

import functions_framework
import hashlib
import base64
import secrets
import json
import os
from flask import redirect, request, jsonify, Response
from urllib.parse import urlencode, quote
import requests

# =============================================================================
# CONFIGURATION
# =============================================================================

# Looker instance — must be set via env vars at deploy time
LOOKER_BASE_URL = os.environ.get("LOOKER_BASE_URL", "https://your-instance.cloud.looker.com")
LOOKER_CLIENT_ID = os.environ.get("LOOKER_CLIENT_ID", "your-looker-oauth-client-id")  # Public client

# This proxy's URL (set after deployment)
PROXY_BASE_URL = os.environ.get("PROXY_BASE_URL", "")

# Secret for validating requests from Gemini (set in Authorization resource)
# Gemini will send this as clientSecret - we validate it but don't forward to Looker
PROXY_CLIENT_SECRET = os.environ.get("PROXY_CLIENT_SECRET", "pkce-proxy-secret-change-me")

# =============================================================================
# PKCE UTILITIES
# =============================================================================

def generate_code_verifier() -> str:
    """Generate a cryptographically random code_verifier (43-128 chars)."""
    return secrets.token_urlsafe(32)  # Produces 43 characters


def generate_code_challenge(code_verifier: str) -> str:
    """Generate code_challenge from code_verifier using S256 method."""
    digest = hashlib.sha256(code_verifier.encode('ascii')).digest()
    return base64.urlsafe_b64encode(digest).rstrip(b'=').decode('ascii')


def wrap_code(real_code: str, code_verifier: str) -> str:
    """
    Wrap the real authorization code and code_verifier into a single string.
    This allows us to pass the verifier through Gemini's OAuth flow without storage.
    """
    payload = json.dumps({"c": real_code, "v": code_verifier}, separators=(',', ':'))
    return base64.urlsafe_b64encode(payload.encode()).decode()


def unwrap_code(wrapped_code: str) -> tuple[str, str]:
    """
    Unwrap to get real authorization code and code_verifier.
    Returns: (real_code, code_verifier)
    """
    try:
        # Add padding if needed
        padded = wrapped_code + '=' * (4 - len(wrapped_code) % 4)
        payload = json.loads(base64.urlsafe_b64decode(padded))
        return payload["c"], payload["v"]
    except Exception as e:
        raise ValueError(f"Invalid wrapped code: {e}")


# =============================================================================
# REQUEST HANDLERS
# =============================================================================

def handle_auth(request):
    """
    /auth - Authorization endpoint
    
    Gemini's Authorization resource points authorizationUri here.
    We generate PKCE params and redirect to Looker's real /auth endpoint.
    """
    # Extract params from Gemini's request
    client_id = request.args.get("client_id", "")
    redirect_uri = request.args.get("redirect_uri", "")  # Gemini's callback (vertexaisearch...)
    state = request.args.get("state", "")
    scope = request.args.get("scope", "cors_api")
    response_type = request.args.get("response_type", "code")
    
    # Gemini may send code_challenge - we ignore it and generate our own for Looker
    # (Gemini's PKCE is between Gemini<->Proxy, our PKCE is between Proxy<->Looker)
    
    # Generate PKCE for Looker
    code_verifier = generate_code_verifier()
    code_challenge = generate_code_challenge(code_verifier)
    
    # Store verifier in state (we'll extract it in callback)
    # Encode: original_state + verifier
    packed_state = wrap_code(state, code_verifier)  # Reusing wrap function for state
    
    # Build Looker auth URL
    looker_params = {
        "client_id": LOOKER_CLIENT_ID,
        "redirect_uri": f"{PROXY_BASE_URL}/callback",
        "response_type": "code",
        "scope": scope,
        "state": packed_state,
        "code_challenge": code_challenge,
        "code_challenge_method": "S256",
    }
    
    looker_auth_url = f"{LOOKER_BASE_URL}/auth?{urlencode(looker_params)}"
    
    print(f"[/auth] Redirecting to Looker: {looker_auth_url[:100]}...")
    return redirect(looker_auth_url)


def handle_callback(request):
    """
    /callback - OAuth callback endpoint
    
    Looker redirects here after user grants permission.
    We wrap the auth code + verifier and redirect to Gemini's callback.
    """
    # Get code and state from Looker
    real_code = request.args.get("code", "")
    packed_state = request.args.get("state", "")
    error = request.args.get("error", "")
    
    if error:
        error_description = request.args.get("error_description", "Unknown error")
        print(f"[/callback] Error from Looker: {error} - {error_description}")
        # Redirect to Gemini with error
        gemini_callback = (
            f"https://vertexaisearch.cloud.google.com/oauth-redirect?"
            f"error={quote(error)}&error_description={quote(error_description)}"
        )
        return redirect(gemini_callback)
    
    # Unpack state to get original_state and code_verifier
    try:
        original_state, code_verifier = unwrap_code(packed_state)
    except ValueError as e:
        print(f"[/callback] Failed to unpack state: {e}")
        return jsonify({"error": "invalid_state", "message": str(e)}), 400
    
    # Wrap the real code + verifier for the /token endpoint
    wrapped_code = wrap_code(real_code, code_verifier)
    
    # Redirect to Gemini's callback with wrapped code
    gemini_params = {
        "code": wrapped_code,
        "state": original_state,  # Return original state to Gemini
    }
    
    gemini_callback = f"https://vertexaisearch.cloud.google.com/oauth-redirect?{urlencode(gemini_params)}"
    
    print(f"[/callback] Redirecting to Gemini with wrapped code")
    return redirect(gemini_callback)


def handle_token(request):
    """
    /token - Token exchange endpoint
    
    Gemini's Authorization resource points tokenUri here.
    We unwrap the code, extract the verifier, and exchange with Looker.
    """
    # Get data from request (could be JSON or form-encoded)
    if request.is_json:
        data = request.get_json()
    else:
        data = request.form.to_dict()
    
    print(f"[/token] Received token request with keys: {list(data.keys())}")
    
    # Extract parameters
    grant_type = data.get("grant_type", "authorization_code")
    wrapped_code = data.get("code", "")
    client_secret = data.get("client_secret", "")
    redirect_uri = data.get("redirect_uri", "")  # Gemini's redirect_uri
    
    # Validate client_secret (this is the proxy's secret, not Looker's)
    if client_secret != PROXY_CLIENT_SECRET:
        print(f"[/token] Invalid client_secret")
        return jsonify({
            "error": "invalid_client",
            "error_description": "Invalid client credentials"
        }), 401
    
    # Handle refresh token requests
    if grant_type == "refresh_token":
        refresh_token = data.get("refresh_token", "")
        return handle_refresh_token(refresh_token)
    
    # Unwrap the code to get real code + verifier
    try:
        real_code, code_verifier = unwrap_code(wrapped_code)
    except ValueError as e:
        print(f"[/token] Failed to unwrap code: {e}")
        return jsonify({
            "error": "invalid_grant",
            "error_description": f"Invalid authorization code: {e}"
        }), 400
    
    # Exchange with Looker using PKCE
    looker_token_data = {
        "grant_type": "authorization_code",
        "client_id": LOOKER_CLIENT_ID,
        "code": real_code,
        "code_verifier": code_verifier,
        "redirect_uri": f"{PROXY_BASE_URL}/callback",
    }
    
    print(f"[/token] Exchanging code with Looker...")
    
    try:
        response = requests.post(
            f"{LOOKER_BASE_URL}/api/token",
            json=looker_token_data,
            headers={"Content-Type": "application/json"},
            timeout=30
        )
        
        print(f"[/token] Looker response status: {response.status_code}")
        
        # Return Looker's response as-is
        return Response(
            response.content,
            status=response.status_code,
            content_type=response.headers.get("Content-Type", "application/json")
        )
        
    except requests.RequestException as e:
        print(f"[/token] Request to Looker failed: {e}")
        return jsonify({
            "error": "server_error",
            "error_description": f"Failed to contact Looker: {e}"
        }), 502


def handle_refresh_token(refresh_token: str):
    """
    Handle refresh token requests.
    Refresh tokens don't need PKCE - just forward to Looker.
    """
    looker_token_data = {
        "grant_type": "refresh_token",
        "client_id": LOOKER_CLIENT_ID,
        "refresh_token": refresh_token,
    }
    
    print(f"[/token] Refreshing token with Looker...")
    
    try:
        response = requests.post(
            f"{LOOKER_BASE_URL}/api/token",
            json=looker_token_data,
            headers={"Content-Type": "application/json"},
            timeout=30
        )
        
        return Response(
            response.content,
            status=response.status_code,
            content_type=response.headers.get("Content-Type", "application/json")
        )
        
    except requests.RequestException as e:
        print(f"[/token] Refresh request to Looker failed: {e}")
        return jsonify({
            "error": "server_error",
            "error_description": f"Failed to contact Looker: {e}"
        }), 502


# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

@functions_framework.http
def main(request):
    """
    Main Cloud Function entry point.
    Routes requests based on path.
    """
    path = request.path
    
    # Add CORS headers for preflight requests
    if request.method == "OPTIONS":
        headers = {
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type, Authorization",
            "Access-Control-Max-Age": "3600",
        }
        return ("", 204, headers)
    
    print(f"[main] {request.method} {path}")
    
    if path == "/auth":
        return handle_auth(request)
    elif path == "/callback":
        return handle_callback(request)
    elif path == "/token":
        return handle_token(request)
    elif path == "/" or path == "":
        return jsonify({
            "service": "PKCE Proxy for Looker OAuth",
            "endpoints": ["/auth", "/callback", "/token"],
            "status": "healthy"
        })
    else:
        return jsonify({"error": "not_found", "message": f"Unknown path: {path}"}), 404