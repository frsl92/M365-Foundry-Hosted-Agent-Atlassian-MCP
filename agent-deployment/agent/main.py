# Copyright (c) Microsoft. All rights reserved.

"""Atlassian assistant using the Activity protocol (bring-your-own).

Hosted by ``azure-ai-agentserver-activity`` for the Foundry platform contract and
bridged to the M365 Agents SDK for activity processing and channel delivery
(e.g. Microsoft Teams).

Jira / Confluence access goes through the Atlassian MCP server exposed in Azure
API Management. APIM maps each Teams user (Entra oid) to that user's own
Atlassian OAuth connection, so every call runs as the person asking. Users who
haven't connected yet get an authorization card (see consent.py).
"""

import logging
import os

from agent_framework import Agent
from agent_framework.foundry import FoundryChatClient
from azure.identity import DefaultAzureCredential
from dotenv import load_dotenv

load_dotenv()

# Configure logging first
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s | %(message)s")
logger = logging.getLogger("atlassian-agent")

from azure.ai.agentserver.activity import ActivityAgentServerHost

from consent import ConsentFlow

# Simple Teams agent auth model is the default.
host = ActivityAgentServerHost()
app = host.agent_app
model_name = os.environ.get("FOUNDRY_MODEL_NAME", "gpt-5.6-luna")

client = FoundryChatClient(
    project_endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
    model=model_name,
    credential=DefaultAzureCredential(),
)

# The Atlassian MCP tool is added per turn (it carries the user's identity),
# so the agent itself is created without tools.
agent = Agent(
    client=client,
    instructions=(
        "You are a helpful Jira and Confluence assistant. Use the Atlassian tools to "
        "answer questions about issues, projects, pages and spaces. You act as the "
        "signed-in user and only see what they can see."
    ),
    # History will be managed by the hosting infrastructure, thus there
    # is no need to store history by the service.
    default_options={"store": False},
)

consent_flow = ConsentFlow(app.auth)

# One session per Teams conversation, so users don't share history.
# In-memory: lost on restart. Move to the hosted agent state store for durability.
_sessions: dict[str, object] = {}


def get_session(context):
    conversation_id = context.activity.conversation.id
    if conversation_id not in _sessions:
        _sessions[conversation_id] = agent.create_session()
    return _sessions[conversation_id]


def log_context_activity(context):
    """Log the inbound activity carried by the turn context."""
    logger.info("[CONTEXT] type=%s | id=%s", context.activity.type, context.activity.id)


@app.activity("message", auth_handlers=["APIM"])
async def on_message(context, state):
    """Handle Atlassian requests and authorization-card submissions."""
    log_context_activity(context)
    try:
        session = get_session(context)
        if await consent_flow.handle_submit(context, agent, session):
            return
        user_text = (context.activity.text or "").strip()
        if user_text:
            await consent_flow.run(context, agent, session, user_text)
    except Exception:  # pylint: disable=broad-exception-caught
        logger.exception("[ERROR] Could not complete the Atlassian request or consent flow.")
        await context.send_activity(
            "Sorry, I could not complete this request. Check the latest response before "
            "trying again, especially if the request changes Jira or Confluence data."
        )


@app.activity("conversationUpdate")
async def on_members_added(context, state):
    """Welcome new members."""
    log_context_activity(context)
    for member in context.activity.members_added or []:
        if member.id != context.activity.recipient.id:
            try:
                await context.send_activity("Hi! Ask me anything about your Jira issues or Confluence pages.")
            except Exception as exc:  # pylint: disable=broad-exception-caught
                logger.warning("[ERROR] Could not send welcome: %s", exc)


@app.error
async def on_error(context, error):
    """Handle unhandled errors."""
    logger.error("[ERROR] HANDLER ERROR | error=%s", error, exc_info=True)
    await context.send_activity(f"Sorry, something went wrong: {error}")


if __name__ == "__main__":
    logger.info("Starting Atlassian agent (bring-your-own) ...")
    host.run()
