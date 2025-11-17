// Copyright (c) 2015-present Mattermost, Inc. All Rights Reserved.
// See LICENSE.txt for license information.

import {connect} from 'react-redux';
import {bindActionCreators} from 'redux';
import type {Dispatch} from 'redux';

import {fetchReadReceiptsCount} from 'actions/read_receipts';

import type {GlobalState} from 'types/store';

import PostReadIndicator from '../post_read_indicator/post_read_indicator';

function mapStateToProps(state: GlobalState, ownProps: {postId: string}) {
    const readCount = state.views.readReceipts?.postReadCounts?.[ownProps.postId] || 0;
    
    return {
        ...ownProps,
        readCount,
    };
}

function mapDispatchToProps(dispatch: Dispatch) {
    return {
        actions: bindActionCreators({
            fetchReadReceiptsCount,
        }, dispatch),
    };
}

export default connect(mapStateToProps, mapDispatchToProps)(PostReadIndicator);
