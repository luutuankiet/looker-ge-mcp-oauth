"""Shim for adk deploy agent_engine which expects agent.py at package root."""
from .looker_mcp_agent.agent import root_agent

__all__ = ["root_agent"]
