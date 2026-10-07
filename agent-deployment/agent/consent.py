# Copyright (c) Microsoft. All rights reserved.

"""Teams cards and single-use retries for MCP OAuth consent.

Consent sources:
- Atlassian via Azure API Management: checked up front through the APIM status
  endpoint, before the agent runs.
- Foundry project-connection MCP tools (e.g. GitHub): reported by the model run as
  ``oauth_consent_request`` user input requests (unchanged from the original flow).
"""

import logging
from dataclasses import dataclass
from time import monotonic
from urllib.parse import urlsplit
from uuid import uuid4

from agent_framework import Agent, AgentSession
from microsoft_agents.activity import Activity, Attachment
from microsoft_agents.hosting.core import TurnContext
from microsoft_agents.hosting.core import Authorization

from atlassian_mcp import (
    atlassian_tool,
    build_headers,
    forget_connection,
    get_atlassian_user_info,
    get_login_link,
    get_user_oid,
    mcp_http_client,
)

logger = logging.getLogger(__name__)

CONTINUE_ACTION = "continue_mcp_consent"
CARD_CONTENT_TYPE = "application/vnd.microsoft.card.adaptive"
PENDING_TTL_SECONDS = 15 * 60
MAX_PENDING_REQUESTS = 100
WHOAMI_COMMANDS = {"/whoami", "whoami", "/me"}


@dataclass
class PendingConsent:
    user_text: str
    owner: tuple[str, str, str]
    expires_at: float
    card_id: str | None = None


def _validate_link(link: object) -> str:
    """Only allow plain https URLs on authorization buttons."""
    if not isinstance(link, str):
        raise ValueError("The provider returned a missing consent URL.")
    parsed = urlsplit(link)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
    ):
        raise ValueError("The provider returned an invalid consent URL.")
    return link


class ConsentFlow:
    """Keep pending prompts in this process; never put them in card submissions."""

    def __init__(self, authorization: Authorization) -> None:
        self.authorization = authorization
        self.pending: dict[str, PendingConsent] = {}


    @staticmethod
    def _owner(context: TurnContext) -> tuple[str, str, str]:
        activity = context.activity
        if (
            not activity.channel_id
            or not activity.conversation
            or not activity.conversation.id
            or not activity.from_property
            or not activity.from_property.id
        ):
            raise ValueError("Consent requires a channel, conversation, and sender.")
        return (
            str(activity.channel_id),
            activity.conversation.id,
            activity.from_property.id,
        )

    def _prune(self) -> None:
        now = monotonic()
        expired = [
            request_id
            for request_id, pending in self.pending.items()
            if pending.expires_at <= now
        ]
        for request_id in expired:
            del self.pending[request_id]

    @staticmethod
    def _card(text: str, actions: list[dict[str, object]]) -> Activity:
        return Activity(
            type="message",
            attachments=[
                Attachment(
                    content_type=CARD_CONTENT_TYPE,
                    content={
                        "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
                        "type": "AdaptiveCard",
                        "version": "1.3",
                        "body": [{"type": "TextBlock", "text": text, "wrap": True}],
                        "actions": actions,
                    },
                )
            ],
        )

    async def _update_card(self, context: TurnContext, card_id: str | None, text: str) -> None:
        if not card_id:
            return
        card = self._card(text, [])
        card.id = card_id
        await context.update_activity(card)

    async def _send_consent_card(
        self,
        context: TurnContext,
        user_text: str,
        links: list[tuple[str, str]],
        card_id: str | None,
    ) -> None:
        """links: (button title, https url) pairs."""
        self._prune()
        if len(self.pending) >= MAX_PENDING_REQUESTS:
            raise RuntimeError("Too many pending authorization requests; try again later.")

        request_id = uuid4().hex
        pending = PendingConsent(
            user_text=user_text,
            owner=self._owner(context),
            expires_at=monotonic() + PENDING_TTL_SECONDS,
            card_id=card_id,
        )
        actions: list[dict[str, object]] = [
            {"type": "Action.OpenUrl", "title": title, "url": link}
            for title, link in links
        ]
        actions.append(
            {
                "type": "Action.Submit",
                "title": "Continue",
                "data": {"action": CONTINUE_ACTION, "request_id": request_id},
            }
        )
        card = self._card(
            "Authorization required. Open the authorization link(s), finish signing in, "
            "then return here and select Continue. Continue retries your pending request; "
            "it does not confirm that consent succeeded. This card expires in 15 minutes.",
            actions,
        )
        self.pending[request_id] = pending
        sent = False
        try:
            if card_id:
                card.id = card_id
                await context.update_activity(card)
            else:
                resource = await context.send_activity(card)
                pending.card_id = resource.id if resource else None
            sent = True
        finally:
            if not sent:
                self.pending.pop(request_id, None)

    async def handle_submit(
        self, context: TurnContext, agent: Agent, session: AgentSession
    ) -> bool:
        data = context.activity.value
        if not isinstance(data, dict) or data.get("action") != CONTINUE_ACTION:
            return False

        self._prune()
        request_id = data.get("request_id")
        if not isinstance(request_id, str) or not request_id:
            logger.warning("Rejected malformed consent continuation.")
            await context.send_activity("Invalid authorization card. Please send your request again.")
            return True

        pending = self.pending.get(request_id)
        if pending is None:
            await context.send_activity(
                "This authorization request has expired, is already being processed, "
                "or is no longer available. Check the latest bot response before sending it again."
            )
            return True
        if pending.owner != self._owner(context):
            logger.warning("Rejected consent continuation from a different sender or conversation.")
            await context.send_activity("Only the person who requested this card can continue it here.")
            return True

        # Claim before any await so repeat clicks cannot run the same operation twice.
        del self.pending[request_id]
        await self._update_card(context, pending.card_id, "Checking authorization and retrying your request...")
        finished = False
        try:
            await self.run(context, agent, session, pending.user_text, pending.card_id)
            finished = True
        finally:
            if not finished:
                await self._update_card(
                    context,
                    pending.card_id,
                    "The retry could not be completed. Check the latest bot response "
                    "before sending the request again.",
                )
        return True

    async def run(
        self,
        context: TurnContext,
        agent: Agent,
        session: AgentSession,
        user_text: str,
        card_id: str | None = None,
    ) -> None:
        # 1. Atlassian consent via APIM: check before running the agent.
        oid = get_user_oid(context)
        if not oid:
            await context.send_activity(
                "I couldn't identify your Microsoft 365 account, so I can't access Atlassian for you."
            )
            await self._update_card(context, card_id, "Your account could not be identified.")
            return

        headers = await build_headers(context, self.authorization)
        login_link = await get_login_link(oid, headers)
        if login_link:
            await self._send_consent_card(
                context, user_text, [("Connect Atlassian", _validate_link(login_link))], card_id
            )
            return

        # 2. Direct command: show the Atlassian account this user is connected as.
        if user_text.strip().lower() in WHOAMI_COMMANDS:
            try:
                await context.send_activity(await get_atlassian_user_info(headers))
            except Exception:
                forget_connection(oid)
                raise
            await self._update_card(context, card_id, "Done. See the bot response.")
            return

        # 3. Run the agent with this user's Atlassian tool.
        received_text = False
        consent_links: list[str] = []
        succeeded = False
        context.streaming_response.queue_informative_update("Thinking hard on your problem.")
        http_client = mcp_http_client(headers)
        try:
            # With store=False, retry the saved prompt with the existing client-side
            # session rather than referencing an unstored backend response ID.
            async with atlassian_tool(http_client) as tool:
                async for chunk in agent.run(user_text, stream=True, session=session, tools=[tool]):
                    if chunk.text:
                        context.streaming_response.queue_text_chunk(chunk.text)
                        received_text = True
                    # Foundry project-connection tools (e.g. GitHub) still report consent here.
                    for request in chunk.user_input_requests:
                        if request.type != "oauth_consent_request":
                            continue
                        link = _validate_link(request.consent_link)
                        if link not in consent_links:
                            consent_links.append(link)
            if consent_links:
                context.streaming_response.queue_text_chunk(
                    "\nAuthorization is required. Use the authorization card to continue."
                )
            elif not received_text:
                context.streaming_response.queue_text_chunk("The model returned no text.")
            succeeded = True
        except Exception:
            # The Atlassian connection may have been revoked: re-check consent next time.
            forget_connection(oid)
            raise
        finally:
            await http_client.aclose()
            if not succeeded:
                context.streaming_response.queue_text_chunk(
                    "\nThe request could not be completed. It will not be retried automatically."
                )
            await context.streaming_response.end_stream()

        if consent_links:
            titles = (
                ["Authorize"]
                if len(consent_links) == 1
                else [f"Authorize connection {i}" for i in range(1, len(consent_links) + 1)]
            )
            await self._send_consent_card(context, user_text, list(zip(titles, consent_links)), card_id)
        else:
            await self._update_card(
                context,
                card_id,
                "The retry finished. See the bot response for the result."
                if received_text
                else "The retry returned no text. Please check your request.",
            )
