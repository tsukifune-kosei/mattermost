// Copyright (c) 2015-present Mattermost, Inc. All Rights Reserved.
// See LICENSE.txt for license information.

import {receivedReadCursorFromWebSocket} from 'actions/read_receipts';

import type {DispatchFunc} from 'mattermost-redux/types/actions';

export function handleReadCursorAdvancedEvent(msg: any) {
    return (dispatch: DispatchFunc) => {
        const data = msg.data;
        
        if (!data || !data.user_id || !data.channel_id) {
            return;
        }

        const cursor = {
            channel_id: data.channel_id,
            user_id: data.user_id,
            last_post_seq: data.last_post_seq,
            updated_at: data.timestamp || Date.now(),
        };

        dispatch(receivedReadCursorFromWebSocket(cursor));
    };
}
