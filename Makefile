APP=mustache
DIALYZER_OPTS=-Werror_handling -Wrace_conditions -Wunmatched_returns

LIBS=$(ERL_LIBS):_build/default/lib

.PHONY: ct
all: compile ct xref dialyze

compile:
	@./rebar3 compile

xref:
	@./rebar3 xref

clean:
	@./rebar3 clean

ct:
	@./rebar3 ct

cover:
	@./rebar3 cover

eunit:
	@./rebar3 eunit

edoc:
	@./rebar3 edoc

start: compile
	@ERL_LIBS=$(LIBS) erl +stbt db +K true -pz ebin -s reloader -eval 'erlang:display(application:ensure_all_started($(APP))).'

dialyze:
	@./rebar3 dialyzer
