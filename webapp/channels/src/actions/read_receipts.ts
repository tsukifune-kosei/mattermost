// Copyright (c) 2015-present Mattermost, Inc. All Rights Reserved.
// See LICENSE.txt for license information.

import {Client4} from 'mattermost-redux/client';

import type {ActionFuncAsync} from 'types/store';

import ActionTypes from 'action_types/read_receipts';
import type {ReadCursor} from 'types/read_receipts';

import type {DispatchFunc, GetStateFunc} from 'mattermost-redux/types/actions';

export function advanceReadCursor(channelId: string, lastPostSeq?: number, postId?: string): ActionFuncAsync<ReadCursor> {
    return async (dispatch) => {
        try {
            const cursor = await Client4.advanceReadCursor(channelId, lastPostSeq, postId);

            dispatch({
                type: ActionTypes.READ_CURSOR_ADVANCED,
                data: cursor,
            });

            return {data: cursor};
        } catch (error) {
            return {error};
        }
    };
}

export function getReadCursor(channelId: string): ActionFuncAsync<ReadCursor> {
    return async (dispatch) => {
        try {
            const cursor = await Client4.getReadCursor(channelId);

            dispatch({
                type: ActionTypes.RECEIVED_READ_CURSOR,
                data: cursor,
            });

            return {data: cursor};
        } catch (error) {
            return {error};
        }
    };
}

export function receivedReadCursorFromWebSocket(cursor: ReadCursor) {
    return {
        type: ActionTypes.RECEIVED_READ_CURSOR,
        data: cursor,
    };
}

export function fetchReadReceiptsCount(postId: string): ActionFuncAsync<{count: number}> {
    return async (dispatch) => {
        try {
            const result = await Client4.getPostReadReceiptsCount(postId);
            
            dispatch({
                type: ActionTypes.RECEIVED_READ_RECEIPTS_COUNT,
                data: {
                    postId,
                    count: result?.count || 0,
                },
            });
            
            return {data: result};
        } catch (error) {
            return {error};
        }
    };
}
