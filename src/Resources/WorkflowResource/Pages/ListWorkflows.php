<?php

namespace Ixys\FilamentWorkflows\Resources\WorkflowResource\Pages;

use App\Models\Expense;
use App\Models\ExpenseCategory;
use Filament\Actions\CreateAction;
use Filament\Resources\Components\Tab;
use Illuminate\Database\Eloquent\Builder;
use Ixys\FilamentWorkflows\Models\Workflow;
use Ixys\FilamentWorkflows\Models\WorkflowGroup;
use Ixys\FilamentWorkflows\Resources\WorkflowResource;
use Filament\Resources\Pages\ListRecords;

class ListWorkflows extends ListRecords
{
    protected static string $resource = WorkflowResource::class;

    protected function getActions(): array
    {
        return [
            CreateAction::make(),
        ];
    }

    public function getTabs(): array
    {
        $groups = WorkflowGroup::with(['workflows'])->whereHas('workflows')->get();

        $data = [];

        foreach ($groups as $group) {
            $data[$group->name] = Tab::make(str($group->name)->title())
                ->modifyQueryUsing(fn(Builder $query) => $query->where('workflow_group_id', $group->id))
                ->badge(Workflow::query()->where('workflow_group_id', $group->id)->count())
                ->badgeColor('success');
        }
        return array_merge(
            [
                'all' => Tab::make(__('filament-workflows::workflows.sections.grouping.all'))
                    ->badge(Workflow::count())
                    ->badgeColor('success')
            ], $data);
    }

    public function getDefaultActiveTab(): string | int | null
    {
        return 'all';
    }
}
