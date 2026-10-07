"""Atlassian MCP (via Azure API Management) helpers.

APIM holds one Atlassian OAuth connection per user (credential manager), keyed by
the user's Entra object ID (oid). Two APIM endpoints are used:

- STATUS endpoint (REST): says whether the user is connected; if not, APIM creates
  the user's connection and returns an Atlassian login link.
- MCP endpoint: the Atlassian MCP server, called with the user's oid.

Environment variables:
    APIM_MCP_URL            required, e.g. https://<apim>.azure-api.net/atlassian-mcp/mcp
    ATLASSIAN_STATUS_URL    required, e.g. https://<apim>.azure-api.net/atlassian-connect/status
    APIM_STATUS_SUBSCRIPTION_KEY   optional, subscription key for the status API
    APIM_MCP_SUBSCRIPTION_KEY      optional, subscription key for the MCP server
"""

import base64
import logging
import os
import time

import json

import httpx
from agent_framework import MCPStreamableHTTPTool
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client
from uuid import UUID

from microsoft_agents.hosting.core import Authorization, TurnContext

logger = logging.getLogger(__name__)

APIM_MCP_URL = os.environ["APIM_MCP_URL"]
ATLASSIAN_STATUS_URL = os.environ["ATLASSIAN_STATUS_URL"]
APIM_STATUS_SUBSCRIPTION_KEY = os.environ.get("APIM_STATUS_SUBSCRIPTION_KEY")
APIM_MCP_SUBSCRIPTION_KEY = os.environ.get("APIM_MCP_SUBSCRIPTION_KEY")

logger.info(
    "[CONFIG] status key set=%s | mcp key set=%s",
    bool(APIM_STATUS_SUBSCRIPTION_KEY),
    bool(APIM_MCP_SUBSCRIPTION_KEY),
)

# After a "connected" answer, skip the status check for this long per user.
CONNECTED_CACHE_SECONDS = 600

_connected_until: dict[str, float] = {}


def get_user_oid(context) -> str | None:
    """The signed-in user's Entra object ID, as sent by Teams."""
    sender = context.activity.from_property
    return getattr(sender, "aad_object_id", None) if sender else None





def _log_apim_token_claims(token: str) -> None:
    """Temporary diagnostics only; APIM remains responsible for token validation."""
    try:
        parts = token.split(".")
        if len(parts) != 3:
            raise ValueError("Expected a JWT.")
        payload = parts[1] + "=" * (-len(parts[1]) % 4)
        claims = json.loads(
            base64.b64decode(payload, altchars=b"-_", validate=True).decode("utf-8")
        )
        if not isinstance(claims, dict):
            raise ValueError("Expected a claims object.")
        selected = {name: claims.get(name) for name in ("aud", "azp", "tid", "ver", "scp")}
        if any(value is not None and not isinstance(value, str) for value in selected.values()):
            raise ValueError("Unexpected claim type.")
    except (ValueError, UnicodeError):
        logger.warning("[AUTH DIAGNOSTIC] Could not decode APIM token claims; token omitted.")
        return

    logger.info("[AUTH DIAGNOSTIC] Unverified APIM token claims: %s", json.dumps(selected))


async def build_headers(
    context: TurnContext,
    authorization: Authorization,
) -> dict[str, str]:
    token_response = await authorization.get_token(context, "APIM")
    if token_response is None or not token_response.token:
        raise RuntimeError("APIM user authentication did not return an access token.")

    _log_apim_token_claims(token_response.token)

    activity = context.activity
    sender = activity.from_property
    oid = getattr(sender, "aad_object_id", None) if sender else None
    tenant_id = getattr(activity.conversation, "tenant_id", None)

    if not tenant_id and isinstance(activity.channel_data, dict):
        tenant = activity.channel_data.get("tenant")
        if isinstance(tenant, dict):
            tenant_id = tenant.get("id")

    if not isinstance(oid, str) or not isinstance(tenant_id, str):
        raise ValueError("Teams user and tenant identifiers are required.")

    print(f"Building headers for oid={oid}, tenant_id={tenant_id}")

    return {
        "Authorization": f"Bearer {token_response.token}",
        "x-teams-user-oid": str(UUID(oid)),
        "x-teams-tenant-id": str(UUID(tenant_id)),
    }



def _with_key(headers: dict[str, str], key: str | None) -> dict[str, str]:
    return {**headers, "Ocp-Apim-Subscription-Key": key} if key else dict(headers)


def forget_connection(oid: str) -> None:
    """Drop the cached 'connected' state so the next message re-checks consent."""
    _connected_until.pop(oid, None)


async def get_login_link(oid: str, headers: dict[str, str]) -> str | None:
    """Return the Atlassian login link if the user still needs to connect, else None."""
    if _connected_until.get(oid, 0) > time.time():
        return None

    async with httpx.AsyncClient(timeout=60) as http:
        response = await http.get(
            ATLASSIAN_STATUS_URL, headers=_with_key(headers, APIM_STATUS_SUBSCRIPTION_KEY)
        )
        response.raise_for_status()
        status = response.json()

    if status.get("connected"):
        _connected_until[oid] = time.time() + CONNECTED_CACHE_SECONDS
        return None

    link = status.get("loginLink")
    if not link:
        raise RuntimeError(f"Status endpoint returned no loginLink: {status}")
    logger.info("[ATLASSIAN] consent required for oid=%s", oid)
    return link


def mcp_http_client(headers: dict[str, str]) -> httpx.AsyncClient:
    """HTTP client carrying this user's headers + the MCP subscription key.

    MCPStreamableHTTPTool has no `headers` argument (unknown kwargs are silently
    ignored), so headers must travel on the http_client. The caller owns the client
    and must close it (await client.aclose()).
    """
    return httpx.AsyncClient(
        headers=_with_key(headers, APIM_MCP_SUBSCRIPTION_KEY),
        timeout=httpx.Timeout(60.0, read=300.0),
    )


def atlassian_tool(http_client: httpx.AsyncClient) -> MCPStreamableHTTPTool:
    """Client-side MCP tool for this turn, using the per-user http_client."""
    return MCPStreamableHTTPTool(
        name="atlassian",
        url=APIM_MCP_URL,
        http_client=http_client,
        description="Search and manage Jira issues and Confluence pages as the signed-in user.",
        approval_mode="never_require",
    )


async def get_atlassian_user_info(headers: dict[str, str]) -> str:
    """Call the Atlassian MCP tool atlassianUserInfo directly (no model) and format it."""
    async with streamablehttp_client(
        APIM_MCP_URL, headers=_with_key(headers, APIM_MCP_SUBSCRIPTION_KEY)
    ) as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.call_tool("atlassianUserInfo", {})

    raw = "\n".join(
        item.text for item in result.content if getattr(item, "type", None) == "text"
    ).strip()
    if result.isError:
        raise RuntimeError(f"atlassianUserInfo failed: {raw}")

    try:
        info = json.loads(raw)
    except ValueError:
        return f"**Atlassian user info**\n\n{raw or '(empty response)'}"

    lines = ["**Atlassian user info**", ""]
    for label, key in (("Name", "name"), ("Email", "email"), ("Account ID", "account_id"),
                       ("Nickname", "nickname"), ("Account status", "account_status")):
        value = info.get(key) if isinstance(info, dict) else None
        if value:
            lines.append(f"- **{label}:** {value}")
    if len(lines) == 2:  # none of the expected fields: show everything
        lines.append("```\n" + json.dumps(info, indent=2) + "\n```")
    return "\n".join(lines)
