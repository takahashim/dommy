require "test_helper"

begin
  require "rails"
  require "action_controller/railtie"
  require "action_mailer/railtie"
  require "dommy/rails/minitest"
rescue LoadError
  warn "Skipping Rails integration tests because Rails is not installed"
  return
end

module DommyRailsTestApp
  class Application < Rails::Application
    config.eager_load = false
    config.secret_key_base = "test-secret"
    config.hosts.clear
    config.logger = Logger.new(nil)
    config.action_controller.allow_forgery_protection = true
    config.action_mailer.delivery_method = :test
    config.action_mailer.default_url_options = { host: "www.example.com" }
  end

  class ArticlesController < ActionController::Base
    protect_from_forgery with: :exception
    skip_forgery_protection only: :create

    def index
      render inline: <<~ERB
        <!doctype html>
        <html>
          <head>
            <title>Articles</title>
            <%= csrf_meta_tags %>
          </head>
          <body>
            <h1>Articles</h1>
            <%= form_with url: "/articles", method: :post do |form| %>
              <%= form.text_field :title %>
            <% end %>
            <a href="http://www.example.com/articles/new?bar=2&amp;foo=1">New article</a>
          </body>
        </html>
      ERB
    end

    def create
      render html: '<turbo-stream action="append" target="articles"><template><div class="article">Hello</div></template></turbo-stream>'.html_safe,
        content_type: "text/vnd.turbo-stream.html"
    end
  end

  class UserMailer < ActionMailer::Base
    default from: "from@example.com"

    def welcome
      mail(to: "to@example.com", subject: "Welcome") do |format|
        format.text { render plain: "Welcome. Confirm your account: http://www.example.com/confirm" }
        format.html { render html: '<a href="http://www.example.com/confirm">Confirm your account</a>'.html_safe }
      end
    end
  end
end

DommyRailsTestApp::Application.initialize! unless DommyRailsTestApp::Application.initialized?

DommyRailsTestApp::Application.routes.draw do
  get "/articles", to: "dommy_rails_test_app/articles#index"
  post "/articles", to: "dommy_rails_test_app/articles#create"
end

class TestRailsIntegration < ActionDispatch::IntegrationTest
  include Dommy::Rails::Minitest::Integration

  def app
    DommyRailsTestApp::Application
  end

  def test_request_response_body_dom_helpers
    get "/articles"

    assert_response :success
    assert_dom_has_title dom, "Articles"
    assert_dom_has_css dom, "h1", text: "Articles"
    assert_dom_has_csrf_meta_tags dom
    assert_dom_has_link dom, "New article", href: "/articles/new?foo=1&bar=2"
    assert_dom_has_form dom, action: "/articles", method: :post
  end

  def test_turbo_stream_response
    post "/articles", headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_dom_appends_turbo_stream response, "articles" do |fragment|
      assert_dom_has_css fragment, ".article", text: "Hello"
    end
  end

  def test_mailer_html_body_can_be_checked
    mail = DommyRailsTestApp::UserMailer.welcome
    body = mail.html_part ? mail.html_part.body.to_s : mail.body.to_s
    document = Dommy.parse(body).document

    assert_dom_has_link document, "Confirm your account", href: "http://www.example.com/confirm"
    assert_mail_has_html_link mail, "Confirm your account", href: "http://www.example.com/confirm"
    assert_mail_has_html_text mail, "Confirm your account"
    assert_mail_has_plain_text mail, "Welcome"
  end
end
