require 'fileutils'
require 'json'

class Sppuppet

  def initialize(settings, client, project, data, event)
    @settings = settings
    @settings['plus_ones_required'] ||= 1
    @settings['reports_dir'] ||= '/var/lib/tutter/reports'
    @client = client
    @project = project
    @data = data
    @event = event
  end

  def debug(message)
    puts message if @debug
  end

  def run
    # If a new pull request is opened, comment with instructions
    if @data['action'] == 'opened' && @settings['post_instructions']
      issue = @data['number']
      comment = @settings['instructions'] || "To merge at least #{@settings['plus_ones_required']} person other than the submitter needs to write a comment with saying _+1_ or :+1:. Then write _!merge_ or :shipit: to trigger the merging."
      begin
        @client.add_comment(@project, issue, comment)
        return 200, "Commented!"
      rescue Octokit::NotFound
        return 404, "Octokit returned 404, this could be an issue with your access token"
      rescue Octokit::Unauthorized
        return 401, "Authorization to #{@project} failed, please verify your access token"
      rescue Octokit::TooManyLoginAttempts
        return 429, "Account for #{@project} has been temporary locked down due to to many failed login attempts"
      end
    end

    if @data['action'] != 'created'
      # Not a new comment, ignore
      return 200, 'not a new comment, skipping'
    end

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

    merge = (comments.last.body == '!merge' || comments.last.body.start_with?(':shipit:'))

    if plus_one.count >= @settings['plus_ones_required'] && merge
      json = { url: pr.url,
               title: pr.title,
               author: pr.user.login,
               description: pr.body,
               commits: @client.pull_request_commits(@project, pr.number).map { |c| { author: c.author.login, message: c.commit.message, sha: c.commit.tree.sha } },
               head_sha: pr.head.sha,
               tests: @client.combined_status(@project, pr.head.sha).statuses.map { |s| {state: s.state, url: s.target_url, description: s.description } },
               reviewers: plus_one.keys,
               deployer: comments.last.user.login }
      # TODO: Word wrap description
      merge_msg <<MERGE_MSG
Title: #{pr.title}
Description: #{pr.body}
Author: #{pr.author}
Reviewers: #{plus_one.keys.join ', '}
Deployer: #{comments.last.user.login}
URL: #{pr.url}
MERGE_MSG
      merge = @client.merge_pull_request(@project, pull_request_id, merge_msg)
      json[:merge_sha] = merge.sha
      report_directory = "#{@settings['reports_dir']}/#{merge_commit.sha[0..1]}/#{merge_commit.sha[2..3]}"
      report_path = "#{report_directory}/#{merge_commit.sha}.json"
      if @settings['generate_reports']
        FileUtils.mkdir_p report_directory
        File.open(report_path, 'w') { |f| f.write(JSON.pretty_generate(json)) }
      end
      return 200, "merging #{pull_request_id} #{@project}"
    elsif plus_one.count >= @settings['plus_ones_required']
      return 200, "have enough +1, but no merge command"
    else
      return 200, "not enough +1, have #{plus_one.count} but need #{@settings['plus_ones_required']}"
    end
  end
end
