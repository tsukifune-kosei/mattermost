// Copyright (c) 2015-present Mattermost, Inc. All Rights Reserved.
// See LICENSE.txt for license information.

import {combineReducers} from 'redux';

import type {AnyAction} from 'redux';

import ActionTypes from 'action_types/read_receipts';
import type {ReadCursor, ReadReceiptsState} from 'types/read_receipts';

function cursors(state: ReadReceiptsState['cursors'] = {}, action: AnyAction): ReadReceiptsState['cursors'] {
    switch (action.type) {
    case ActionTypes.RECEIVED_READ_CURSOR:
    case ActionTypes.READ_CURSOR_ADVANCED: {
        const cursor = action.data as ReadCursor;
        const {channel_id, user_id} = cursor;

        return {
            ...state,
            [channel_id]: {
                ...state[channel_id],
                [user_id]: cursor,
            },
        };
    }
    default:
        return state;
    }
}

function postReadCounts(state: Record<string, number> = {}, action: AnyAction): Record<string, number> {
    switch (action.type) {
    case ActionTypes.RECEIVED_READ_RECEIPTS_COUNT: {
        const {postId, count} = action.data;
        return {
            ...state,
            [postId]: count,
        };
    }
    default:
        return state;
    }
}

export default combineReducers({
    cursors,
    postReadCounts,
});
