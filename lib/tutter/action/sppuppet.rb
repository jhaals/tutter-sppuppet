class Sppuppet

  def initialize(settings, client, project, data, event)
    @settings = settings
    @settings['plus_ones_required'] ||= 1
    @client = client
    @project = project
    @data = data
    @event = event
  end

  def debug(message)
    puts message if @debug
  end

  def run
    pull_request_id = @data['issue']['number']
    pr = @client.pull_request @project, pull_request_id
    plus_one = {}
    merge = false

    if pr.mergeable_state != 'clean'
      return 200, "merge state for #{@project} #{pull_request_id} is not clean. Current state: #{pr.mergeable_state}"
    end

    # No comments, no need to go further.
    if pr.comments == 0
      return 200, 'no comments, skipping'
    end

    # Don't care about code we can't merge
    return 200, 'merge state not clean' unless pr.mergeable

    # We fetch the latest commit and it's date.
    last_commit = @client.pull_request_commits(@project, pull_request_id).last
    last_commit_date = last_commit.commit.committer.date

    comments = @client.issue_comments(@project, pull_request_id)

    # Check each comment for +1 and merge comments
    comments.each do |i|

      # Comment is older than last commit. We only want to check for +1 in newer comments
      next if last_commit_date > i.created_at

      if /^(\+1|:\+1)/.match i.body
        # pull request submitter cant +1
        unless pr.user.login == i.attrs[:user].attrs[:login]
          plus_one[i.attrs[:user].attrs[:login]] = 1
        end
      end

      # TODO it should calculate the +1's - the -1's
      # Never merge if someone says -1
      if /^(\-1|:\-1:)/.match i.body
        return 200, "#{@project} #{pull_request_id} has a -1. I will not take the blame"
      end
    end

    merge = true if comments.last.body == '!merge'

    if plus_one.count >= @settings['plus_ones_required'] and merge
      @client.merge_pull_request(@project, pull_request_id, 'SHIPPING!!')
      return 200, "merging #{pull_request_id} #{@project}"
    elsif plus_one.count >= @settings['plus_ones_required']
      return 200, "have enough +1, but no merge command"
    else
      return 200, "not enough +1, have #{plus_one.count} but need #{@settings['plus_ones_required']}"
    end
  end
end
