#define KNIFE_CONFIG "sourcemod/pugsetup/knife.cfg"
Handle g_KnifeCvarRestore = INVALID_HANDLE;

public Action StartKnifeRound(Handle timer) {
  if (g_GameState != GameState_KnifeRound)
    return Plugin_Handled;

  // reset player tags
  for (int i = 1; i <= MaxClients; i++) {
    if (IsPlayer(i)) {
      UpdateClanTag(i, true);  // force strip them
    }
  }

  g_KnifeCvarRestore = ExecuteAndSaveCvars(KNIFE_CONFIG);
  if (g_KnifeCvarRestore == INVALID_HANDLE) {
    LogError("Failed to save cvar values when executing %s", KNIFE_CONFIG);
  }

  RestartGame(1);
  g_KnifeRoundVotesCast = 0;
  for (int i = 1; i <= MaxClients; i++) {
    g_KnifeRoundVotes[i] = KnifeDecision_None;
  }

  // This is done on a delay since the cvar changes from
  // the knife cfg execute have their own delay of when they are printed
  // into global chat.
  CreateTimer(1.0, Timer_AnnounceKnife);
  return Plugin_Handled;
}

public Action Timer_AnnounceKnife(Handle timer) {
  if (g_GameState != GameState_KnifeRound)
    return Plugin_Handled;

  for (int i = 0; i < 5; i++)
    PugSetup_MessageToAll("%t", "KnifeRound");
  return Plugin_Handled;
}

public Action Timer_HandleKnifeDecisionVote(Handle timer) {
  HandleKnifeDecisionVote();
}

public void HandleKnifeDecisionVote() {
  if (g_GameState != GameState_WaitingForKnifeRoundDecision) {
    return;
  }

  int stayCount = 0;
  int swapCount = 0;
  for (int i = 1; i <= MaxClients; i++) {
    if (IsValidClient(i) && GetClientTeam(i) == g_KnifeWinner) {
      if (g_KnifeRoundVotes[i] == KnifeDecision_Stay)
        stayCount++;
      else if (g_KnifeRoundVotes[i] == KnifeDecision_Swap)
        swapCount++;
    }
  }
  bool doSwap = (swapCount > stayCount);
  EndKnifeRound(doSwap);
}

public void EndKnifeRound(bool swap) {
  Call_StartForward(g_hOnKnifeRoundDecision);
  Call_PushCell(swap);
  Call_Finish();

  if (swap) {
    for (int i = 1; i <= MaxClients; i++) {
      if (IsValidClient(i)) {
        int team = GetClientTeam(i);
        if (team == CS_TEAM_T)
          SwitchPlayerTeam(i, CS_TEAM_CT);
        else if (team == CS_TEAM_CT)
          SwitchPlayerTeam(i, CS_TEAM_T);
      }
    }
  }

  ChangeState(GameState_GoingLive);
  if (g_KnifeCvarRestore != INVALID_HANDLE) {
    RestoreCvars(g_KnifeCvarRestore);
    CloseCvarStorage(g_KnifeCvarRestore);
    g_KnifeCvarRestore = INVALID_HANDLE;
  }
  CreateTimer(3.0, BeginLO3, _, TIMER_FLAG_NO_MAPCHANGE);
}

static bool AwaitingDecision(int client, const char[] command) {
  if (g_DoVoteForKnifeRoundDecisionCvar.IntValue != 0) {
    return (g_GameState == GameState_WaitingForKnifeRoundDecision) && IsPlayer(client) &&
           GetClientTeam(client) == g_KnifeWinner;
  } else {
    // Always lets console make the decision
    if (client == 0)
      return true;

    // Check if they're on the winning team
    bool canMakeDecision = (g_GameState == GameState_WaitingForKnifeRoundDecision) &&
                           IsPlayer(client) && GetClientTeam(client) == g_KnifeWinner;
    bool hasPermissions = DoPermissionCheck(client, command);
    return canMakeDecision && hasPermissions;
  }
}

public Action Command_Stay(int client, int args) {
  if (AwaitingDecision(client, "sm_stay")) {
    if (g_DoVoteForKnifeRoundDecisionCvar.IntValue == 0) {
      EndKnifeRound(false);
    } else {
      g_KnifeRoundVotes[client] = KnifeDecision_Stay;
      PugSetup_Message(client, "%t", "KnifeRoundVoteStay");
      g_KnifeRoundVotesCast++;
      if (g_KnifeRoundVotesCast == g_PlayersPerTeam) {
        HandleKnifeDecisionVote();
      }
    }
  }
  return Plugin_Handled;
}

public Action Command_Swap(int client, int args) {
  if (AwaitingDecision(client, "sm_swap")) {
    if (g_DoVoteForKnifeRoundDecisionCvar.IntValue == 0) {
      EndKnifeRound(true);
    } else {
      g_KnifeRoundVotes[client] = KnifeDecision_Swap;
      PugSetup_Message(client, "%t", "KnifeRoundVoteSwap");
      g_KnifeRoundVotesCast++;
      if (g_KnifeRoundVotesCast == g_PlayersPerTeam) {
        HandleKnifeDecisionVote();
      }
    }
  }
  return Plugin_Handled;
}

public Action Command_Ct(int client, int args) {
  if (IsPlayer(client)) {
    if (GetClientTeam(client) == CS_TEAM_CT)
      FakeClientCommand(client, "sm_stay");
    else if (GetClientTeam(client) == CS_TEAM_T)
      FakeClientCommand(client, "sm_swap");
  }
  return Plugin_Handled;
}

public Action Command_T(int client, int args) {
  if (IsPlayer(client)) {
    if (GetClientTeam(client) == CS_TEAM_T)
      FakeClientCommand(client, "sm_stay");
    else if (GetClientTeam(client) == CS_TEAM_CT)
      FakeClientCommand(client, "sm_swap");
  }
  return Plugin_Handled;
}

public int GetKnifeRoundWinner() {
  int ctAlive = CountAlivePlayersOnTeam(CS_TEAM_CT);
  int tAlive = CountAlivePlayersOnTeam(CS_TEAM_T);
  int winningCSTeam = CS_TEAM_NONE;
  if (ctAlive > tAlive) {
    winningCSTeam = CS_TEAM_CT;
  } else if (tAlive > ctAlive) {
    winningCSTeam = CS_TEAM_T;
  } else {
    int ctHealth = SumHealthOfTeam(CS_TEAM_CT);
    int tHealth = SumHealthOfTeam(CS_TEAM_T);
    if (ctHealth > tHealth) {
      winningCSTeam = CS_TEAM_CT;
    } else if (tHealth > ctHealth) {
      winningCSTeam = CS_TEAM_T;
    } else {
      if (GetRandomFloat(0.0, 1.0) < 0.5) {
        winningCSTeam = CS_TEAM_CT;
      } else {
        winningCSTeam = CS_TEAM_T;
      }
    }
  }

  return winningCSTeam;
}
