import type { NextApiRequest, NextApiResponse } from "next";

import { withSessionAuthentication } from "@app/lib/api/auth_wrappers";
import { createAndLogMembership } from "@app/lib/api/signup";
import type { SessionWithUser } from "@app/lib/iam/provider";
import { getUserFromSession } from "@app/lib/iam/session";
import { createWorkspace } from "@app/lib/iam/workspaces";
import config from "@app/lib/api/config";
import { MembershipInvitationResource } from "@app/lib/resources/membership_invitation_resource";
import { MembershipResource } from "@app/lib/resources/membership_resource";
import { UserResource } from "@app/lib/resources/user_resource";
import { apiError } from "@app/logger/withlogging";
import type { WithAPIErrorResponse } from "@app/types";

async function handler(
  req: NextApiRequest,
  res: NextApiResponse<WithAPIErrorResponse<{ sId: string }>>,
  session: SessionWithUser
): Promise<void> {
  if (req.method !== "POST") {
    return apiError(req, res, {
      status_code: 405,
      api_error: {
        type: "method_not_supported_error",
        message: "The method passed is not supported, POST is expected.",
      },
    });
  }

  const user = await getUserFromSession(session);

  if (!user) {
    return apiError(req, res, {
      status_code: 401,
      api_error: {
        type: "invalid_request_error",
        message: "The user is not found.",
      },
    });
  }

  if (user.workspaces.length > 0) {
    return apiError(req, res, {
      status_code: 400,
      api_error: {
        type: "invalid_request_error",
        message: "The user already has a workspace.",
      },
    });
  }

  const userResource = await UserResource.fetchByModelId(user.id);
  if (!userResource) {
    return apiError(req, res, {
      status_code: 404,
      api_error: {
        type: "user_not_found",
        message: "The user was not found.",
      },
    });
  }

  const { memberships } = await MembershipResource.getActiveMemberships({
    users: [userResource],
  });
  const pendingInvitations =
    memberships.length === 0
      ? await MembershipInvitationResource.listPendingForEmail({
          email: user.email,
        })
      : null;

  if (
    !config.isWorkspaceCreationAllowedWithoutInvite() &&
    memberships.length === 0 &&
    (!pendingInvitations || pendingInvitations.length === 0)
  ) {
    return apiError(req, res, {
      status_code: 403,
      api_error: {
        type: "workspace_auth_error",
        message: "No active membership or invitation found for this user.",
      },
    });
  }

  const workspace = await createWorkspace(session);

  await createAndLogMembership({
    user: userResource,
    workspace,
    role: "admin",
    origin: "invited",
  });

  res.status(200).json({ sId: workspace.sId });
}

export default withSessionAuthentication(handler);
