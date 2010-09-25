# Issue Extensions plugin for Redmine
# Copyright (C) 2010  Takashi Takebayashi
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
class IssueExtensionsIssueHooks < Redmine::Hook::Listener
#  def controller_issues_new_before_save(context)
#    issue = context[:issue]
#    project = Project.find(issue[:project_id].to_i)
#    unless (project.module_enabled?(:issue_extensions) == nil)
#      issue_status_assigned(context)
#      issue_status_closed(context)
#    end
#  end

  def controller_issues_edit_before_save context
    issue = context[:issue]
    project = Project.find issue[:project_id].to_i
    unless project.module_enabled? :issue_extensions == nil
      issue_status_assigned context
      issue_status_closed context
      issue_added_watcher context
    end
  end

  def controller_issues_bulk_edit_before_save context
    issue = context[:issue]
    params = context[:params]
    project = Project.find issue[:project_id].to_i
    unless project.module_enabled? :issue_extensions == nil
      # Redmine 0.9.3 では、呼び元で issue[:status_id] に params[:status_id] の値を設定しない為、対応
      issue[:status_id] = params[:status_id].blank? ? issue[:status_id] : params[:status_id]
      context[:issue] = issue
      issue_status_closed context
    end
  end

  def controller_issues_new_after_save context
    issue = context[:issue]
    project = Project.find issue[:project_id].to_i
    unless project.module_enabled? :issue_extensions == nil
      issue_added_relation context
    end
  end

  private
  # チケットに担当者が設定されている && 状態が新規の場合、担当に変更する
  def issue_status_assigned context
    issue = context[:issue]
    issue_status = IssueExtensionsStatusFlow.find :first, :conditions => ['project_id = ?', issue[:project_id].to_i]

    if issue_status.old_status_id == issue[:status_id]
        issue[:status_id] = issue_status.new_status_id
        context[:issue] = issue
      end if issue[:assigned_to_id] != nil && issue_status != nil
  end

  # チケットがクローズされている場合、進捗を100%に変更する
  def issue_status_closed context
    issue = context[:issue]
    issue_status_closed = IssueStatus.find :all, :conditions => ["is_closed = (?)", true]

    issue_status_closed.each {|closed|
      if closed.id == issue[:status_id].to_i && issue[:done_ratio] != 100
          issue[:done_ratio] = 100
          context[:issue] = issue
        end if issue[:status_id] != nil && issue[:done_ratio] != nil
    } unless issue_status_closed.length == 0
  end

  # チケットを更新した場合、更新者をウォッチャーに追加する
  def issue_added_watcher context
    issue = context[:issue]
    journal = context[:journal]

    if Watcher.find :first, :conditions =>["watchable_type = (?) and watchable_id = (?) and user_id = (?)", journal[:journalized_type], issue[:id].to_i, journal[:user_id].to_i] == nil
        hash_watcher = HashWithIndifferentAccess.new
        hash_watcher[:user_id]  = journal[:user_id].to_s
        watcher = Watcher.new(hash_watcher)
        watcher.watchable_type  = journal[:journalized_type].to_s
        watcher.watchable_id    = issue[:id].to_i
        watcher.save
      end if journal != nil && journal[:journalized_type] != nil && issue[:id] != nil && journal[:user_id] != nil
  end

  # 関連チケットを指定している場合、関連付けする
  def issue_added_relation context
    issue = context[:issue]
    params = context[:params]
    unless params[:relation_issue_id] == nil
      from_issue = Issue.find :first, :conditions =>["id = (?)", params[:relation_issue_id].to_i]
      unless from_issue == nil
        relation = IssueRelation.new
        relation.relation_type = IssueRelation::TYPE_RELATES
        relation.issue_from_id = params[:relation_issue_id]
        relation.issue_to_id = issue.id
        relation.save!
      end
    end
  end

  class IssueExtensionsIssueViewListener < Redmine::Hook::ViewListener
    # 関連したチケットの作成ページへのリンクを追記する
    def view_issues_show_description_bottom context
      issue = context[:issue]
      project = context[:project]
      return '' unless project
      request = context[:request]
      parameters = request.parameters
      cb_subject = parameters[:cb_subject]
      cb_subject = "" unless cb_subject
      searched_issues = nil
      searched_issues = Issue.find(:all, :conditions => ["subject IN (?)", cb_subject]) if cb_subject
      begin
          output = "<hr />\n"
          output << "<div id=\"issue_extensions_relations\">\n"
          output << "  " + link_to(l(:label_add_relation_issue), {:controller => 'issues', :action => 'new', :project_id => project, :relation_issue => issue.id}, :class => 'icon icon-edit' ) + "\n"
          output << "</div>\n"
          output << "<div id=\"issue_extensions_search\">\n"
          output << "  " + link_to(l(:button_apply), {:controller => 'issues', :action => 'show', :project_id => project, :cb_subject => cb_subject}, :class => 'icon icon-checked') + "\n"
          output << "  <fieldset class=\"searched-issues\" inner-droppableid=\"searched-issues\"><legend>" + l(:label_searched_issues) + "</legend>\n"
          output << "    <ul id=\"ul_searched-issues\" class=\"inner-droppable\">\n"
          searched_issues.each do |searched_issue|
            output << "      <li id=issue_" + searched_issue.id + " class=\"draggable\">"
            output << "<span class=" + 'moved' if searched_issue.closed? + ">"
            output << searched_issue.issue.tracker.to_s + " #" + searched_issue.id.to_s + ":" + h(searched_issue.subject) + "</li>\n"
            end unless searched_issues.length == 0
          output << "    </ul>\n"
          output << "  </fieldset>\n"
          output << "</div>\n"
          return output
        rescue
        end unless project.module_enabled? :issue_extensions == nil
    end

    # 関連元のチケットのIDを埋め込む
    def view_issues_form_details_bottom context
      project = context[:project]
      request = context[:request]
      parameters = request.parameters
      relation_issue = parameters[:relation_issue]
      return '' unless relation_issue
      begin
          output = hidden_field_tag :relation_issue_id, relation_issue
          return output
        rescue
        end unless project.module_enabled? :issue_extensions == nil
    end
  end
end
